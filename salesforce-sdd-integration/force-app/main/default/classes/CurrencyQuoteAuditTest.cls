/**
 * CurrencyQuoteAuditTest
 *
 * Qué prueba: la Historia 3 (auditoría). Que cada cotización sea un registro independiente, que no se
 * pueda borrar una Oportunidad con cotizaciones (el historial nunca se pierde) y que el auditor pueda
 * consultar el historial en solo lectura, sin acceso al Log de Errores.
 */
@IsTest
private with sharing class CurrencyQuoteAuditTest {

    @TestSetup
    static void createData() {
        QuoteTestDataFactory.createOpportunity(10000, 'USD');
    }

    /**
     * En la vida real las tres cotizaciones llegan en llamadas distintas (transacciones distintas).
     * En un test todo corre en una sola transacción y Apex no permite un callout después de un insert,
     * así que las pedimos en una misma lista: el efecto sobre el historial es el mismo.
     */
    @IsTest
    static void tresCotizacionesGeneranTresRegistrosIndependientes() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());
        List<QuoteModels.QuoteRequest> requests = new List<QuoteModels.QuoteRequest>();
        for (String targetCurrency : new List<String>{ 'EUR', 'GBP', 'EUR' }) {
            requests.addAll(quoteRequests(opportunityId, targetCurrency));
        }

        Test.startTest();
        OpportunityQuoteService.quote(requests, OpportunityQuoteService.CHANNEL_EXTERNAL);
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM CurrencyQuote__c WHERE Opportunity__c = :opportunityId],
            'Tres cotizaciones, ninguna reemplaza a otra');
    }

    @IsTest
    static void noSePuedeBorrarUnaOportunidadConCotizaciones() {
        Id opportunityId = createQuote();

        Boolean deleteBlocked = false;
        try {
            delete new Opportunity(Id = opportunityId);
        } catch (DmlException e) {
            deleteBlocked = true;
        }

        Assert.isTrue(deleteBlocked, 'La relación impide borrar la Oportunidad (FR-020a)');
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity WHERE Id = :opportunityId], 'La Oportunidad sigue');
        Assert.areEqual(1, [SELECT COUNT() FROM CurrencyQuote__c], 'El historial sigue');
    }

    @IsTest
    static void elAuditorPuedeLeerPeroNoModificarElHistorial() {
        createQuote();
        User auditor = QuoteTestDataFactory.createUser('Standard User', new List<String>{ 'CurrencyQuoteAuditor' });

        System.runAs(auditor) {
            List<CurrencyQuote__c> visible = [SELECT Id, ConvertedAmount__c FROM CurrencyQuote__c WITH USER_MODE];
            Assert.areEqual(1, visible.size(), 'El auditor ve el historial');

            Assert.isFalse(Schema.SObjectType.CurrencyQuote__c.isUpdateable(), 'El auditor no puede editar');
            Assert.isFalse(Schema.SObjectType.CurrencyQuote__c.isDeletable(), 'El auditor no puede borrar');
            Assert.isFalse(Schema.SObjectType.CurrencyQuote__c.isCreateable(), 'El auditor no puede crear');

            Boolean updateBlocked = false;
            try {
                visible[0].ConvertedAmount__c = 1;
                Database.update(visible, AccessLevel.USER_MODE);
            } catch (Exception e) {
                updateBlocked = true;
            }
            Assert.isTrue(updateBlocked, 'La edición se rechaza (FR-020)');
        }
    }

    @IsTest
    static void elAuditorNoVeElLogDeErrores() {
        User auditor = QuoteTestDataFactory.createUser('Standard User', new List<String>{ 'CurrencyQuoteAuditor' });

        System.runAs(auditor) {
            Assert.isFalse(Schema.SObjectType.ErrorLog__c.isAccessible(), 'El log es solo para administradores (FR-024)');
        }
    }

    /** Crea una cotización real a través del Service y devuelve el Id de la Oportunidad. */
    private static Id createQuote() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());
        Test.startTest();
        OpportunityQuoteService.quote(quoteRequests(opportunityId, 'EUR'), OpportunityQuoteService.CHANNEL_EXTERNAL);
        Test.stopTest();
        return opportunityId;
    }

    private static List<QuoteModels.QuoteRequest> quoteRequests(Id opportunityId, String targetCurrency) {
        QuoteModels.QuoteRequest request = new QuoteModels.QuoteRequest();
        request.opportunityId = opportunityId;
        request.targetCurrency = targetCurrency;
        return new List<QuoteModels.QuoteRequest>{ request };
    }
}
