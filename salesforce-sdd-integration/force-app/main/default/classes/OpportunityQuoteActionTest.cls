/**
 * OpportunityQuoteActionTest
 *
 * Qué prueba: la acción del agente (OpportunityQuoteAction): que devuelva los mismos datos que el
 * Service (SC-006), que los errores vuelvan como isSuccess = false sin inventar valores y que tanto
 * las cotizaciones como los errores queden registrados con el canal "Agent".
 */
@IsTest
private with sharing class OpportunityQuoteActionTest {

    @TestSetup
    static void createData() {
        QuoteTestDataFactory.createOpportunity(10000, 'USD');
    }

    @IsTest
    static void devuelveLosSeisDatosDeLaCotizacion() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        List<OpportunityQuoteAction.Response> responses = OpportunityQuoteAction.quote(actionRequests(opportunityId, 'EUR'));
        Test.stopTest();

        OpportunityQuoteAction.Response response = responses[0];
        Assert.isTrue(response.isSuccess, 'Éxito');
        Assert.areEqual(10000, response.originalAmount, 'Monto original');
        Assert.areEqual('USD', response.originalCurrency, 'Moneda original');
        Assert.areEqual('EUR', response.targetCurrency, 'Moneda destino');
        Assert.areEqual(0.87889, response.exchangeRate, 'Tipo de cambio');
        Assert.areEqual(8788.90, response.convertedAmount, 'Monto convertido');
        Assert.isTrue(response.quotedAt.endsWith('Z'), 'Fecha/hora en ISO 8601 UTC: ' + response.quotedAt);
        for (String expected : new List<String>{ '10000.00', 'USD', '8788.90', 'EUR', '0.87889', response.quotedAt }) {
            Assert.isTrue(response.message.contains(expected), 'El resumen menciona ' + expected + ': ' + response.message);
        }
        Assert.areEqual('Agent', [SELECT Channel__c FROM CurrencyQuote__c].Channel__c, 'Canal del agente');
    }

    /**
     * SC-006: el agente y el canal externo dan los mismos valores. No podemos llamar a los dos canales
     * en el mismo test (el segundo callout vendría después del insert del primero, y Apex no lo
     * permite), así que comparamos contra el mismo resultado que verifica OpportunityQuoteResourceTest
     * para el mismo mock: 10000 USD × 0.75396 = 7539.60 GBP.
     */
    @IsTest
    static void devuelveLosMismosValoresQueElCanalExterno() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        OpportunityQuoteAction.Response fromAgent = OpportunityQuoteAction.quote(actionRequests(opportunityId, 'GBP'))[0];
        Test.stopTest();

        Assert.areEqual(10000, fromAgent.originalAmount, 'SC-006: monto original');
        Assert.areEqual(0.75396, fromAgent.exchangeRate, 'SC-006: tipo de cambio');
        Assert.areEqual(7539.60, fromAgent.convertedAmount, 'SC-006: monto convertido');
    }

    @IsTest
    static void unaOportunidadInexistenteVuelveComoErrorClaro() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        OpportunityQuoteAction.Response response = OpportunityQuoteAction.quote(actionRequests('006000000000000AAA', 'EUR'))[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'Falla');
        Assert.areEqual(QuoteException.OPPORTUNITY_NOT_FOUND, response.errorCode, 'Código');
        Assert.areEqual('Pedido 1 (Id 006000000000000AAA): la Oportunidad indicada no existe.', response.message,
            'Mismo mensaje que recibiría el sistema externo');
        ErrorLog__c log = [SELECT Channel__c FROM ErrorLog__c WITH SYSTEM_MODE];
        Assert.areEqual('Agent', log.Channel__c, 'El log registra el canal del agente');
    }

    @IsTest
    static void conElProveedorCaidoNoInventaValores() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock().withTimeout('USD'));

        Test.startTest();
        OpportunityQuoteAction.Response response = OpportunityQuoteAction.quote(actionRequests(opportunityId, 'EUR'))[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess, 'Falla');
        Assert.areEqual(QuoteException.EXCHANGE_RATE_UNAVAILABLE, response.errorCode, 'Código');
        Assert.areEqual(QuoteException.MESSAGE_UNAVAILABLE, response.message, 'Mensaje claro');
        Assert.isNull(response.exchangeRate, 'Sin tipo de cambio inventado');
        Assert.isNull(response.convertedAmount, 'Sin monto inventado');
        Assert.areEqual(0, [SELECT COUNT() FROM CurrencyQuote__c], 'No se guarda nada');
    }

    private static List<OpportunityQuoteAction.Request> actionRequests(String opportunityId, String targetCurrency) {
        OpportunityQuoteAction.Request request = new OpportunityQuoteAction.Request();
        request.opportunityId = opportunityId;
        request.targetCurrency = targetCurrency;
        return new List<OpportunityQuoteAction.Request>{ request };
    }
}
