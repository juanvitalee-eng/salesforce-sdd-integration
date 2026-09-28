/**
 * OpportunityQuoteResourceTest
 *
 * Qué prueba: la "puerta" REST (OpportunityQuoteResource): que el JSON de respuesta respete
 * exactamente el contrato, que los códigos HTTP sean los correctos y que ningún error exponga
 * detalles técnicos (SC-005). La lógica de negocio en sí se prueba en OpportunityQuoteServiceTest.
 */
@IsTest
private with sharing class OpportunityQuoteResourceTest {

    @TestSetup
    static void createData() {
        QuoteTestDataFactory.createOpportunity(10000, 'USD');
    }

    @IsTest
    static void respondeOkConElJsonDelContrato() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        RestResponse response = post('{"requests":[{"opportunityId":"' + opportunityId + '","targetCurrency":"eur"}]}');

        Assert.areEqual(200, response.statusCode, 'HTTP 200');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(response.responseBody.toString());
        List<Object> quotes = (List<Object>) body.get('quotes');
        Assert.areEqual(1, quotes.size(), 'Una cotización');
        Map<String, Object> quote = (Map<String, Object>) quotes[0];
        Assert.areEqual(
            new Set<String>{ 'opportunityId', 'originalAmount', 'originalCurrency', 'targetCurrency',
                             'exchangeRate', 'convertedAmount', 'quotedAt', 'rateDate' },
            quote.keySet(), 'Propiedades exactas del contrato');
        Assert.areEqual(8788.90, (Decimal) quote.get('convertedAmount'), 'Monto convertido');
        Assert.isTrue(((String) quote.get('quotedAt')).endsWith('Z'), 'quotedAt en ISO 8601 UTC');
        Assert.areEqual('2026-09-28', quote.get('rateDate'), 'rateDate en formato YYYY-MM-DD');
        Assert.areEqual('ExternalSystem', [SELECT Channel__c FROM CurrencyQuote__c].Channel__c, 'Canal externo');
    }

    @IsTest
    static void respondeBadRequestConElDetalleDelPedidoQueFallo() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        RestResponse response = post('{"requests":[{"opportunityId":"006000000000000AAA","targetCurrency":"EUR"}]}');

        Assert.areEqual(400, response.statusCode, 'HTTP 400');
        Map<String, Object> error = errorOf(response);
        Assert.areEqual('OPPORTUNITY_NOT_FOUND', error.get('code'), 'Código');
        Assert.areEqual(1, error.get('requestIndex'), 'Posición');
        Assert.areEqual('006000000000000AAA', error.get('opportunityId'), 'Id del pedido');
        Assert.isTrue(((String) error.get('message')).contains('no existe'), 'Mensaje claro');
        assertNoTechnicalDetails(response);
    }

    @IsTest
    static void respondeBadRequestSiElBodyNoEsJson() {
        RestResponse response = post('esto no es JSON');

        Assert.areEqual(400, response.statusCode, 'HTTP 400');
        Map<String, Object> error = errorOf(response);
        Assert.areEqual('INVALID_REQUEST_BODY', error.get('code'), 'Código');
        Assert.isNull(error.get('requestIndex'), 'Error de toda la llamada');
        Assert.areEqual(1, [SELECT COUNT() FROM ErrorLog__c], 'Deja registro en el log');
        assertNoTechnicalDetails(response);
    }

    @IsTest
    static void respondeBadRequestSiFaltaLaListaDePedidos() {
        RestResponse response = post('{}');

        Assert.areEqual(400, response.statusCode, 'HTTP 400');
        Assert.areEqual('INVALID_REQUEST_BODY', errorOf(response).get('code'), 'Código');
    }

    @IsTest
    static void respondeBadRequestSiLaListaEstaVacia() {
        RestResponse response = post('{"requests":[]}');

        Assert.areEqual(400, response.statusCode, 'HTTP 400');
        Assert.areEqual('EMPTY_REQUEST_LIST', errorOf(response).get('code'), 'Código');
    }

    @IsTest
    static void respondeErrorDelServicioSiElProveedorEstaCaido() {
        Id opportunityId = [SELECT Id FROM Opportunity LIMIT 1].Id;
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock().withStatus('USD', 503, 'Service Unavailable'));

        RestResponse response = post('{"requests":[{"opportunityId":"' + opportunityId + '","targetCurrency":"EUR"}]}');

        Assert.areEqual(500, response.statusCode, 'HTTP 500');
        Assert.areEqual('EXCHANGE_RATE_UNAVAILABLE', errorOf(response).get('code'), 'Código');
        Assert.areEqual(0, [SELECT COUNT() FROM CurrencyQuote__c], 'No se guarda nada');
        assertNoTechnicalDetails(response);
    }

    // ------------------------------------------------------------------ Ayudantes

    /** Simula un POST al endpoint con el body indicado y devuelve la respuesta. */
    private static RestResponse post(String body) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/v1/opportunity-quotes';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(body);
        RestContext.request = request;
        RestContext.response = new RestResponse();

        Test.startTest();
        OpportunityQuoteResource.quote();
        Test.stopTest();
        return RestContext.response;
    }

    private static Map<String, Object> errorOf(RestResponse response) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(response.responseBody.toString());
        return (Map<String, Object>) body.get('error');
    }

    /** SC-005: ninguna respuesta de error contiene detalles técnicos internos. */
    private static void assertNoTechnicalDetails(RestResponse response) {
        String body = response.responseBody.toString();
        for (String forbidden : new List<String>{ 'Exception', 'line ', 'Class.', 'OpportunityQuoteService', 'HTTP 5' }) {
            Assert.isFalse(body.contains(forbidden), 'La respuesta no debe contener "' + forbidden + '": ' + body);
        }
    }
}
