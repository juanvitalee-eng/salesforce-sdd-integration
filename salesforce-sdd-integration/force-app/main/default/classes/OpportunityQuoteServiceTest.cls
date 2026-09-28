/**
 * OpportunityQuoteServiceTest
 *
 * Qué prueba: toda la lógica de cotización (OpportunityQuoteService): escenarios de aceptación de
 * la Historia 1, casos borde de la spec, truncado, "todo o nada", prioridad por posición, cantidad
 * de callouts, guardado del historial y registro en el Log de Errores.
 *
 * Nunca llama a la API real (usa ExchangeRateCalloutMock). Los datos se crean en @TestSetup y las
 * llamadas al Service van entre Test.startTest() y Test.stopTest() (ver tasks.md, "Tests con callouts").
 */
@IsTest
private with sharing class OpportunityQuoteServiceTest {

    private static final String CHANNEL = OpportunityQuoteService.CHANNEL_EXTERNAL;
    private static final String MISSING_OPPORTUNITY_ID = '006000000000000AAA';

    @TestSetup
    static void createData() {
        QuoteTestDataFactory.createOpportunity(10000, 'USD');
        QuoteTestDataFactory.createOpportunity(5000, 'EUR');
        QuoteTestDataFactory.createOpportunity(1000, 'ARS');
        QuoteTestDataFactory.createOpportunity(null, 'USD');
    }

    // ------------------------------------------------------------------ Escenarios de aceptación

    @IsTest
    static void cotizaUnaOportunidadEnUsdAEur() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        List<QuoteModels.QuoteResult> results = OpportunityQuoteService.quote(requests(usd.Id, 'EUR'), CHANNEL);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Un resultado por pedido');
        QuoteModels.QuoteResult result = results[0];
        Assert.areEqual(String.valueOf(usd.Id), result.opportunityId, 'Id de Oportunidad');
        Assert.areEqual(10000, result.originalAmount, 'Monto original');
        Assert.areEqual('USD', result.originalCurrency, 'Moneda original');
        Assert.areEqual('EUR', result.targetCurrency, 'Moneda destino');
        Assert.areEqual(0.87889, result.exchangeRate, 'Tipo de cambio');
        Assert.areEqual(8788.90, result.convertedAmount, 'Monto convertido = 10000 × 0.87889');
        Assert.isNotNull(result.quotedAt, 'Fecha/hora de cotización');
        Assert.areEqual(Date.newInstance(2026, 9, 28), result.rateDate, 'Fecha de publicación');

        CurrencyQuote__c saved = [
            SELECT Opportunity__c, OriginalAmount__c, OriginalCurrency__c, TargetCurrency__c, ExchangeRate__c,
                   ConvertedAmount__c, QuotedAt__c, RateDate__c, Channel__c
            FROM CurrencyQuote__c
        ];
        Assert.areEqual(usd.Id, saved.Opportunity__c, 'Cotización vinculada a la Oportunidad');
        Assert.areEqual(10000, saved.OriginalAmount__c, 'Monto original guardado');
        Assert.areEqual('USD', saved.OriginalCurrency__c, 'Moneda original guardada');
        Assert.areEqual('EUR', saved.TargetCurrency__c, 'Moneda destino guardada');
        Assert.areEqual(0.87889, saved.ExchangeRate__c, 'Tipo de cambio guardado');
        Assert.areEqual(8788.90, saved.ConvertedAmount__c, 'Monto convertido guardado');
        Assert.areEqual(result.quotedAt, saved.QuotedAt__c, 'Fecha/hora guardada');
        Assert.areEqual(result.rateDate, saved.RateDate__c, 'Fecha de publicación guardada');
        Assert.areEqual(CHANNEL, saved.Channel__c, 'Canal de origen');
        Assert.areEqual(0, errorLogCount(), 'Una cotización exitosa no genera log de errores');
        assertOpportunityUnchanged(usd);
    }

    @IsTest
    static void devuelveLosResultadosEnElMismoOrdenQueLosPedidos() {
        Opportunity usd = opportunity(10000, 'USD');
        Opportunity eur = opportunity(5000, 'EUR');
        ExchangeRateCalloutMock mock = ExchangeRateCalloutMock.usdDefault()
            .withRates('EUR', Date.newInstance(2026, 9, 28), new Map<String, Decimal>{ 'USD' => 1.1378 });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<QuoteModels.QuoteResult> results = OpportunityQuoteService.quote(new List<QuoteModels.QuoteRequest>{
            request(usd.Id, 'EUR'), request(eur.Id, 'USD'), request(usd.Id, 'GBP')
        }, CHANNEL);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'Un resultado por pedido');
        Assert.areEqual('EUR', results[0].targetCurrency, 'Pedido 1');
        Assert.areEqual(5689.00, results[1].convertedAmount, 'Pedido 2: 5000 × 1.1378');
        Assert.areEqual('GBP', results[2].targetCurrency, 'Pedido 3');
        Assert.areEqual(2, mock.callCount, 'Un callout por moneda original distinta (USD y EUR)');
        Assert.areEqual(3, [SELECT COUNT() FROM CurrencyQuote__c], 'Una cotización guardada por pedido');
    }

    @IsTest
    static void rechazaUnaOportunidadInexistente() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        QuoteException error = expectError(requests(MISSING_OPPORTUNITY_ID, 'EUR'),
            QuoteException.OPPORTUNITY_NOT_FOUND, 400, 1);

        Assert.isTrue(error.getMessage().contains('no existe'), 'Mensaje claro: ' + error.getMessage());
        Assert.areEqual(MISSING_OPPORTUNITY_ID, error.opportunityId, 'Informa el Id que falló');
        ErrorLog__c log = [SELECT ErrorCode__c, StatusCode__c, Channel__c, RelatedRecordId__c, Context__c
                           FROM ErrorLog__c WITH SYSTEM_MODE];
        Assert.areEqual(QuoteException.OPPORTUNITY_NOT_FOUND, log.ErrorCode__c, 'Código en el log');
        Assert.areEqual(400, log.StatusCode__c, 'HTTP en el log');
        Assert.areEqual(CHANNEL, log.Channel__c, 'Canal en el log');
        Assert.areEqual(MISSING_OPPORTUNITY_ID, log.RelatedRecordId__c, 'Id válido → se guarda como relacionado');
        Assert.areEqual('Pedido 1 de 1, Id recibido: ' + MISSING_OPPORTUNITY_ID, log.Context__c, 'Contexto');
    }

    @IsTest
    static void rechazaUnaMonedaDestinoNoSoportada() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        QuoteException error = expectError(requests(usd.Id, 'XYZ'), QuoteException.UNSUPPORTED_CURRENCY, 400, 1);
        Assert.isTrue(error.getMessage().contains('moneda destino XYZ'), 'Mensaje: ' + error.getMessage());
    }

    @IsTest
    static void rechazaUnaMonedaOriginalNoSoportada() {
        Opportunity ars = opportunity(1000, 'ARS');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault()); // ARS no configurada → 404

        QuoteException error = expectError(requests(ars.Id, 'EUR'), QuoteException.UNSUPPORTED_CURRENCY, 400, 1);
        Assert.isTrue(error.getMessage().contains('moneda original ARS'), 'Mensaje: ' + error.getMessage());
    }

    @IsTest
    static void respondeNoDisponibleSiElProveedorFalla() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock().withStatus('USD', 500, 'boom'));

        QuoteException error = expectError(requests(usd.Id, 'EUR'), QuoteException.EXCHANGE_RATE_UNAVAILABLE, 500, 1);
        Assert.areEqual(QuoteException.MESSAGE_UNAVAILABLE, error.getMessage(), 'Mensaje genérico, sin detalles técnicos');
        ErrorLog__c log = [SELECT TechnicalDetail__c FROM ErrorLog__c WITH SYSTEM_MODE];
        Assert.isTrue(log.TechnicalDetail__c.contains('HTTP 500'), 'El detalle técnico queda solo en el log');
    }

    @IsTest
    static void respondeNoDisponibleSiElProveedorNoRespondeATiempo() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock().withTimeout('USD'));

        expectError(requests(usd.Id, 'EUR'), QuoteException.EXCHANGE_RATE_UNAVAILABLE, 500, 1);
    }

    @IsTest
    static void unPedidoInvalidoEnElMedioRechazaTodaLaLista() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        QuoteException error = expectError(new List<QuoteModels.QuoteRequest>{
            request(usd.Id, 'EUR'), request(MISSING_OPPORTUNITY_ID, 'EUR'), request(usd.Id, 'GBP')
        }, QuoteException.OPPORTUNITY_NOT_FOUND, 400, 2);

        Assert.isTrue(error.getMessage().startsWith('Pedido 2'), 'El mensaje identifica el pedido 2');
        Assert.areEqual(0, [SELECT COUNT() FROM CurrencyQuote__c], 'Todo o nada: ni siquiera los pedidos 1 y 3');
    }

    // ------------------------------------------------------------------ Monedas habilitadas (FR-025, FR-026)

    @IsTest
    static void rechazaUnaMonedaDestinoNoHabilitadaSinConsultarAlProveedor() {
        Opportunity usd = opportunity(10000, 'USD');
        ExchangeRateCalloutMock mock = ExchangeRateCalloutMock.usdDefault();
        Test.setMock(HttpCalloutMock.class, mock);

        QuoteException error = expectError(requests(usd.Id, 'BTC'), QuoteException.UNSUPPORTED_CURRENCY, 400, 1);

        Assert.isTrue(error.getMessage().contains('moneda destino BTC no está habilitada'), 'Mensaje: ' + error.getMessage());
        Assert.areEqual(0, mock.callCount, 'FR-026: se rechaza antes de consultar al proveedor');
    }

    @IsTest
    static void rechazaUnaMonedaOriginalNoHabilitadaSinConsultarAlProveedor() {
        Opportunity usd = opportunity(10000, 'USD');
        OpportunityQuoteSettings.enabledCurrenciesOverride = new Set<String>{ 'EUR', 'GBP' }; // USD desactivada
        ExchangeRateCalloutMock mock = ExchangeRateCalloutMock.usdDefault();
        Test.setMock(HttpCalloutMock.class, mock);

        QuoteException error = expectError(requests(usd.Id, 'EUR'), QuoteException.UNSUPPORTED_CURRENCY, 400, 1);

        Assert.isTrue(error.getMessage().contains('moneda original USD no está habilitada'), 'Mensaje: ' + error.getMessage());
        Assert.areEqual(0, mock.callCount, 'FR-026: se rechaza antes de consultar al proveedor');
    }

    @IsTest
    static void rechazaUnaMonedaHabilitadaQueElProveedorNoPublica() {
        Opportunity usd = opportunity(10000, 'USD');
        OpportunityQuoteSettings.enabledCurrenciesOverride = new Set<String>{ 'USD', 'UYU' };
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault()); // el mock no publica UYU

        QuoteException error = expectError(requests(usd.Id, 'UYU'), QuoteException.UNSUPPORTED_CURRENCY, 400, 1);
        Assert.isTrue(error.getMessage().contains('no es publicada por el proveedor'), 'Mensaje: ' + error.getMessage());
    }

    @IsTest
    static void cotizaUnaOportunidadEnArsConUnaTasaDeMuchosDecimales() {
        Opportunity ars = opportunity(1000, 'ARS');
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock().withRates(
            'ARS', Date.newInstance(2026, 9, 28), new Map<String, Decimal>{ 'USD' => 0.00065713162 }));

        Test.startTest();
        QuoteModels.QuoteResult result = OpportunityQuoteService.quote(requests(ars.Id, 'USD'), CHANNEL)[0];
        Test.stopTest();

        Assert.areEqual(0.00065713162, result.exchangeRate, 'Se usa la tasa completa del proveedor');
        Assert.areEqual(0.65, result.convertedAmount, '1000 × 0,00065713162 = 0,657… → truncado 0,65');
        Decimal savedRate = [SELECT ExchangeRate__c FROM CurrencyQuote__c].ExchangeRate__c;
        Assert.areEqual(0.0006571316, savedRate.setScale(10, System.RoundingMode.HALF_UP),
            'Se guarda con al menos 10 decimales, sin perder precisión (FR-012)');
    }

    @IsTest
    static void lasMonedasHabilitadasSalenDelCustomMetadata() {
        Set<String> enabled = OpportunityQuoteSettings.enabledCurrencies();
        Assert.isTrue(enabled.contains('ARS'), 'ARS viene habilitada de fábrica');
        Assert.isTrue(enabled.contains('USD'), 'USD viene habilitada de fábrica');
        Assert.isFalse(enabled.contains('BTC'), 'Las criptomonedas no están habilitadas');
    }

    // ------------------------------------------------------------------ Casos borde

    @IsTest
    static void rechazaUnaOportunidadSinMonto() {
        Opportunity withoutAmount = [SELECT Id FROM Opportunity WHERE Amount = null LIMIT 1];
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        expectError(requests(withoutAmount.Id, 'EUR'), QuoteException.OPPORTUNITY_WITHOUT_AMOUNT, 400, 1);
    }

    @IsTest
    static void mismaMonedaUsaTipoDeCambioUno() {
        Opportunity usd = opportunity(10000, 'USD');
        ExchangeRateCalloutMock mock = ExchangeRateCalloutMock.usdDefault();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        QuoteModels.QuoteResult result = OpportunityQuoteService.quote(requests(usd.Id, 'USD'), CHANNEL)[0];
        Test.stopTest();

        Assert.areEqual(1, result.exchangeRate, 'Misma moneda → tasa 1');
        Assert.areEqual(10000, result.convertedAmount, 'Monto convertido = monto original');
        Assert.areEqual(1, mock.callCount, 'Igual se consulta al proveedor para validar la moneda');
        Assert.areEqual(1, [SELECT COUNT() FROM CurrencyQuote__c], 'Se registra como cualquier cotización');
    }

    @IsTest
    static void aceptaLaMonedaEnMinusculas() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        QuoteModels.QuoteResult result = OpportunityQuoteService.quote(requests(usd.Id, ' eur '), CHANNEL)[0];
        Test.stopTest();

        Assert.areEqual('EUR', result.targetCurrency, 'Se normaliza a mayúsculas');
    }

    @IsTest
    static void rechazaUnCodigoDeMonedaConFormatoIncorrecto() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        QuoteException error = expectError(requests(usd.Id, 'euro'), QuoteException.INVALID_CURRENCY_CODE, 400, 1);
        Assert.isTrue(error.getMessage().contains('"euro"'), 'Mensaje: ' + error.getMessage());
    }

    @IsTest
    static void rechazaUnaMonedaVacia() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        expectError(requests(usd.Id, ''), QuoteException.INVALID_CURRENCY_CODE, 400, 1);
    }

    @IsTest
    static void rechazaUnIdDeOtroObjeto() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        expectError(requests('001000000000000AAA', 'EUR'), QuoteException.INVALID_OPPORTUNITY_ID, 400, 1);
    }

    @IsTest
    static void rechazaUnIdMalFormadoYIgualDejaElLog() {
        String longInvalidId = 'x'.repeat(30);
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        expectError(requests(longInvalidId, 'EUR'), QuoteException.INVALID_OPPORTUNITY_ID, 400, 1);

        ErrorLog__c log = [SELECT RelatedRecordId__c, Context__c FROM ErrorLog__c WITH SYSTEM_MODE];
        Assert.isNull(log.RelatedRecordId__c, 'Un Id inválido no se guarda como registro relacionado');
        Assert.isTrue(log.Context__c.contains(longInvalidId), 'El valor crudo queda en el contexto');
    }

    @IsTest
    static void rechazaUnPedidoNulo() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        expectError(new List<QuoteModels.QuoteRequest>{ null }, QuoteException.INVALID_OPPORTUNITY_ID, 400, 1);
    }

    @IsTest
    static void rechazaUnaListaVacia() {
        QuoteException error = expectError(new List<QuoteModels.QuoteRequest>(), QuoteException.EMPTY_REQUEST_LIST, 400, null);
        Assert.isNull(error.opportunityId, 'Es un error de toda la llamada');
        Assert.areEqual(1, errorLogCount(), 'También deja registro en el log');
    }

    @IsTest
    static void rechazaUnaListaNula() {
        expectError(null, QuoteException.EMPTY_REQUEST_LIST, 400, null);
    }

    @IsTest
    static void rechazaMasPedidosQueElMaximoConfigurado() {
        Opportunity usd = opportunity(10000, 'USD');
        OpportunityQuoteSettings.testOverride = new OpportunityQuoteSetting__mdt(MaxRequestsPerCall__c = 2);

        QuoteException error = expectError(new List<QuoteModels.QuoteRequest>{
            request(usd.Id, 'EUR'), request(usd.Id, 'EUR'), request(usd.Id, 'EUR')
        }, QuoteException.REQUEST_LIMIT_EXCEEDED, 400, null);
        Assert.isTrue(error.getMessage().contains('2'), 'El mensaje indica el máximo: ' + error.getMessage());
    }

    @IsTest
    static void unIdRepetidoGeneraResultadosYRegistrosIndependientes() {
        Opportunity usd = opportunity(10000, 'USD');
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        List<QuoteModels.QuoteResult> results = OpportunityQuoteService.quote(new List<QuoteModels.QuoteRequest>{
            request(usd.Id, 'EUR'), request(usd.Id, 'GBP')
        }, CHANNEL);
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Dos resultados');
        Assert.areEqual(2, [SELECT COUNT() FROM CurrencyQuote__c WHERE Opportunity__c = :usd.Id], 'Dos registros');
    }

    // ------------------------------------------------------------------ Truncado (FR-012)

    @IsTest
    static void truncaElMontoConvertidoSinRedondear() {
        Opportunity positive = QuoteTestDataFactory.createOpportunity(100, 'USD');
        Opportunity negative = QuoteTestDataFactory.createOpportunity(-100, 'USD');
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock().withRates(
            'USD', Date.newInstance(2026, 9, 28), new Map<String, Decimal>{ 'EUR' => 1.234569 }));

        Test.startTest();
        List<QuoteModels.QuoteResult> results = OpportunityQuoteService.quote(new List<QuoteModels.QuoteRequest>{
            request(positive.Id, 'EUR'), request(negative.Id, 'EUR')
        }, CHANNEL);
        Test.stopTest();

        Assert.areEqual(123.45, results[0].convertedAmount, '123,4569 → 123,45 (no 123,46)');
        Assert.areEqual(-123.45, results[1].convertedAmount, '-123,4569 → -123,45 (hacia cero)');
    }

    // ------------------------------------------------------------------ Prioridad y volumen

    @IsTest
    static void ganaElErrorDeMenorPosicionAunqueElProveedorEsteCaido() {
        Opportunity usd = opportunity(10000, 'USD');
        ExchangeRateCalloutMock mock = new ExchangeRateCalloutMock().withStatus('USD', 500, 'boom');
        Test.setMock(HttpCalloutMock.class, mock);

        expectError(new List<QuoteModels.QuoteRequest>{
            request('no-es-un-id', 'EUR'), request(usd.Id, 'EUR')
        }, QuoteException.INVALID_OPPORTUNITY_ID, 400, 1);

        Assert.areEqual(0, mock.callCount, 'Si el pedido 1 ya falló, no hace falta consultar al proveedor');
    }

    @IsTest
    static void cotiza200PedidosConUnSoloCallout() {
        Opportunity usd = opportunity(10000, 'USD');
        ExchangeRateCalloutMock mock = ExchangeRateCalloutMock.usdDefault();
        Test.setMock(HttpCalloutMock.class, mock);
        List<QuoteModels.QuoteRequest> batch = new List<QuoteModels.QuoteRequest>();
        for (Integer i = 0; i < 200; i++) {
            batch.add(request(usd.Id, Math.mod(i, 2) == 0 ? 'EUR' : 'GBP'));
        }

        Test.startTest();
        List<QuoteModels.QuoteResult> results = OpportunityQuoteService.quote(batch, CHANNEL);
        Test.stopTest();

        Assert.areEqual(200, results.size(), '200 resultados (SC-008)');
        Assert.areEqual(1, mock.callCount, 'Un solo callout para 200 pedidos en USD');
        Assert.areEqual(200, [SELECT COUNT() FROM CurrencyQuote__c], '200 cotizaciones guardadas');
    }

    // ------------------------------------------------------------------ Permisos y errores inesperados

    @IsTest
    static void unUsuarioConElPermissionSetPuedeCotizar() {
        Opportunity usd = opportunity(10000, 'USD');
        User quoter = QuoteTestDataFactory.createUser('Standard User', new List<String>{ 'OpportunityQuoteUser' });
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        System.runAs(quoter) {
            OpportunityQuoteService.quote(requests(usd.Id, 'EUR'), CHANNEL);
        }
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM CurrencyQuote__c], 'La cotización se guarda con permisos de usuario');
    }

    @IsTest
    static void unErrorInesperadoSeInformaComoErrorInterno() {
        Opportunity usd = opportunity(10000, 'USD');
        // Sin el permission set, el usuario no puede crear CurrencyQuote__c: el insert falla.
        User withoutPermission = QuoteTestDataFactory.createUser('Standard User', null);
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        QuoteException caught;
        System.runAs(withoutPermission) {
            try {
                OpportunityQuoteService.quote(requests(usd.Id, 'EUR'), CHANNEL);
            } catch (QuoteException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'Debería haber fallado');
        Assert.areEqual(QuoteException.INTERNAL_ERROR, caught.errorCode, 'Código');
        Assert.areEqual(500, caught.httpStatus, 'HTTP 500');
        Assert.areEqual(QuoteException.MESSAGE_INTERNAL, caught.getMessage(), 'Mensaje genérico');
        Assert.areEqual(0, [SELECT COUNT() FROM CurrencyQuote__c], 'No se guardó nada');
        Assert.areEqual(1, errorLogCount(), 'Queda registro en el log');
    }

    // ------------------------------------------------------------------ Ayudantes

    /**
     * Busca la Oportunidad de @TestSetup con esa moneda y ese monto. El monto se compara en Apex
     * (no en SOQL) porque en una org multimoneda SOQL compara montos convertidos a la moneda corporativa.
     */
    private static Opportunity opportunity(Decimal amount, String currencyIsoCode) {
        for (Opportunity candidate : [SELECT Id, Amount, CurrencyIsoCode FROM Opportunity
                                      WHERE CurrencyIsoCode = :currencyIsoCode AND Amount != null]) {
            if (candidate.Amount == amount) {
                return candidate;
            }
        }
        return null;
    }

    private static QuoteModels.QuoteRequest request(String opportunityId, String targetCurrency) {
        QuoteModels.QuoteRequest request = new QuoteModels.QuoteRequest();
        request.opportunityId = opportunityId;
        request.targetCurrency = targetCurrency;
        return request;
    }

    private static List<QuoteModels.QuoteRequest> requests(String opportunityId, String targetCurrency) {
        return new List<QuoteModels.QuoteRequest>{ request(opportunityId, targetCurrency) };
    }

    private static Integer errorLogCount() {
        return [SELECT COUNT() FROM ErrorLog__c];
    }

    /**
     * Llama al Service esperando un error, y verifica código, HTTP, posición, que no se haya
     * guardado ninguna cotización y que haya exactamente un registro en el log (SC-003, SC-009).
     */
    private static QuoteException expectError(List<QuoteModels.QuoteRequest> batch, String code, Integer status, Integer index) {
        QuoteException caught;
        Test.startTest();
        try {
            OpportunityQuoteService.quote(batch, CHANNEL);
        } catch (QuoteException e) {
            caught = e;
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'Debería haber lanzado QuoteException con código ' + code);
        Assert.areEqual(code, caught.errorCode, 'Código de error');
        Assert.areEqual(status, caught.httpStatus, 'Código HTTP');
        Assert.areEqual(index, caught.requestIndex, 'Posición del pedido que falló');
        Assert.areEqual(0, [SELECT COUNT() FROM CurrencyQuote__c], 'Un rechazo no guarda cotizaciones');
        Assert.areEqual(1, errorLogCount(), 'Un rechazo deja exactamente un log');
        return caught;
    }

    private static void assertOpportunityUnchanged(Opportunity before) {
        Opportunity after = [SELECT Amount, CurrencyIsoCode FROM Opportunity WHERE Id = :before.Id];
        Assert.areEqual(before.Amount, after.Amount, 'La Oportunidad no cambia su monto (SC-004)');
        Assert.areEqual(before.CurrencyIsoCode, after.CurrencyIsoCode, 'La Oportunidad no cambia su moneda');
    }
}
