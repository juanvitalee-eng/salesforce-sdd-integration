/**
 * ExchangeRateClientTest
 *
 * Qué prueba: que ExchangeRateClient traduce bien cada respuesta del proveedor (currency-api):
 * tasas OK, moneda no soportada (404), errores del proveedor, timeout y respuestas ilegibles.
 * Nunca llama a la API real: usa ExchangeRateCalloutMock (regla 13).
 */
@IsTest
private with sharing class ExchangeRateClientTest {

    @IsTest
    static void devuelveLasTasasCuandoElProveedorRespondeOk() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateCalloutMock.usdDefault());

        Test.startTest();
        Map<String, ExchangeRateClient.RateTable> tables = ExchangeRateClient.getRates(new Set<String>{ 'USD' });
        Test.stopTest();

        ExchangeRateClient.RateTable usd = tables.get('USD');
        Assert.isTrue(usd.isSupported, 'USD debería estar soportada');
        Assert.areEqual(0.87889, usd.rates.get('EUR'), 'Tasa USD→EUR');
        Assert.areEqual(Date.newInstance(2026, 9, 28), usd.rateDate, 'Fecha de publicación');
        Assert.isNotNull(usd.fetchedAt, 'Debe registrar cuándo se obtuvo la tasa');
    }

    @IsTest
    static void marcaComoNoSoportadaUnaMonedaQueDevuelve404() {
        Test.setMock(HttpCalloutMock.class, new ExchangeRateCalloutMock()); // sin configurar → 404

        Test.startTest();
        Map<String, ExchangeRateClient.RateTable> tables = ExchangeRateClient.getRates(new Set<String>{ 'ARS' });
        Test.stopTest();

        Assert.isFalse(tables.get('ARS').isSupported, 'ARS no está soportada por el proveedor');
    }

    @IsTest
    static void lanzaNoDisponibleCuandoElProveedorDevuelve500() {
        assertUnavailable(new ExchangeRateCalloutMock().withStatus('USD', 500, 'Internal error'), 'USD');
    }

    @IsTest
    static void lanzaNoDisponibleCuandoElProveedorDevuelve429() {
        assertUnavailable(new ExchangeRateCalloutMock().withStatus('USD', 429, 'Too many requests'), 'USD');
    }

    @IsTest
    static void lanzaNoDisponibleCuandoElProveedorNoRespondeATiempo() {
        assertUnavailable(new ExchangeRateCalloutMock().withTimeout('USD'), 'USD');
    }

    @IsTest
    static void lanzaNoDisponibleCuandoLaRespuestaEsIlegible() {
        assertUnavailable(new ExchangeRateCalloutMock().withStatus('USD', 200, '<html>no es JSON</html>'), 'USD');
    }

    @IsTest
    static void lanzaNoDisponibleCuandoLaRespuestaEstaIncompleta() {
        assertUnavailable(new ExchangeRateCalloutMock().withStatus('USD', 200, '{"usd":{"eur":0.9}}'), 'USD');
    }

    @IsTest
    static void haceUnCalloutPorMonedaBaseUsandoLaNamedCredential() {
        ExchangeRateCalloutMock mock = ExchangeRateCalloutMock.usdDefault()
            .withRates('EUR', Date.newInstance(2026, 9, 28), new Map<String, Decimal>{ 'USD' => 1.1378 });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Map<String, ExchangeRateClient.RateTable> tables = ExchangeRateClient.getRates(new Set<String>{ 'USD', 'EUR' });
        Test.stopTest();

        Assert.areEqual(2, mock.callCount, 'Debe hacer exactamente un callout por moneda base');
        Assert.areEqual(2, tables.size(), 'Debe devolver una tabla por moneda base');
        for (String endpoint : mock.endpoints) {
            Assert.isTrue(endpoint.startsWith('callout:CurrencyApi/currencies/'), 'Usa la Named Credential: ' + endpoint);
        }
    }

    @IsTest
    static void usaMinusculasConElProveedorYMayusculasHaciaAdentro() {
        ExchangeRateCalloutMock mock = new ExchangeRateCalloutMock().withRates(
            'ARS', Date.newInstance(2026, 9, 28), new Map<String, Decimal>{ 'USD' => 0.00065713162 });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ExchangeRateClient.RateTable ars = ExchangeRateClient.getRates(new Set<String>{ 'ARS' }).get('ARS');
        Test.stopTest();

        Assert.areEqual('callout:CurrencyApi/currencies/ars.json', mock.endpoints[0], 'El código va en minúsculas en la URL');
        Assert.areEqual(0.00065713162, ars.rates.get('USD'), 'Las claves se devuelven en MAYÚSCULAS y con todos los decimales');
        Assert.areEqual(1, ars.rates.get('ARS'), 'La base dentro del mapa no se confunde con la clave de afuera');
    }

    @IsTest
    static void noHaceCalloutsSiNoHayMonedas() {
        ExchangeRateCalloutMock mock = new ExchangeRateCalloutMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Map<String, ExchangeRateClient.RateTable> tables = ExchangeRateClient.getRates(new Set<String>());
        Test.stopTest();

        Assert.isTrue(tables.isEmpty(), 'Sin monedas no hay tablas');
        Assert.areEqual(0, mock.callCount, 'Sin monedas no hay callouts');
    }

    /** Verifica que el cliente lance ExchangeRateUnavailableException con el mock indicado. */
    private static void assertUnavailable(ExchangeRateCalloutMock mock, String base) {
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        try {
            ExchangeRateClient.getRates(new Set<String>{ base });
            Assert.fail('Debería haber lanzado ExchangeRateUnavailableException');
        } catch (ExchangeRateUnavailableException e) {
            Assert.areEqual(QuoteException.EXCHANGE_RATE_UNAVAILABLE, e.errorCode, 'Código de error');
            Assert.areEqual(500, e.httpStatus, 'HTTP 500');
            Assert.isNotNull(e.technicalDetail, 'Debe guardar el detalle técnico para el log');
        }
        Test.stopTest();
    }
}
