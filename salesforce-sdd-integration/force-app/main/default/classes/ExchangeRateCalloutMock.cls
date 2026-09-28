/**
 * ExchangeRateCalloutMock
 *
 * Qué hace: simula al proveedor de tipo de cambio (currency-api) durante los tests.
 * Se le dice qué responder para cada moneda base: tasas, un código de error o un timeout.
 *
 * Por qué existe: la regla 13 de la constitución prohíbe tests que dependan de la API real.
 * Con este "doble" los tests son rápidos, repetibles y pueden simular fallas a voluntad.
 *
 * Además cuenta cuántas llamadas recibió (callCount) para verificar que se hace un solo callout
 * por moneda base y no uno por pedido.
 *
 * Si se pide una moneda base que no fue configurada, responde 404 (igual que currency-api con una
 * moneda que no publica).
 */
@IsTest
public with sharing class ExchangeRateCalloutMock implements HttpCalloutMock {

    private Map<String, Integer> statusByBase = new Map<String, Integer>();
    private Map<String, String> bodyByBase = new Map<String, String>();
    private Set<String> timeoutBases = new Set<String>();

    public Integer callCount = 0;                       // Cuántos callouts recibió
    public List<String> endpoints = new List<String>(); // A qué URLs se llamó, en orden

    /**
     * Configura una respuesta 200 con las tasas indicadas para una moneda base, con el mismo formato
     * que currency-api: códigos en minúsculas y la moneda base como clave del mapa de tasas.
     *   {"date":"2026-09-28","usd":{"usd":1,"eur":0.87889,...}}
     * Incluye la propia base dentro del mapa (como hace el proveedor real) para probar que el
     * cliente no la confunde con la clave de afuera.
     */
    public ExchangeRateCalloutMock withRates(String base, Date rateDate, Map<String, Decimal> rates) {
        Map<String, Decimal> providerRates = new Map<String, Decimal>{ base.toLowerCase() => 1 };
        for (String code : rates.keySet()) {
            providerRates.put(code.toLowerCase(), rates.get(code));
        }
        String body = '{"date":"' + String.valueOf(rateDate) + '","' + base.toLowerCase() + '":'
            + JSON.serialize(providerRates) + '}';
        return withStatus(base, 200, body);
    }

    /** Configura un código HTTP y un body cualquiera para una moneda base. */
    public ExchangeRateCalloutMock withStatus(String base, Integer status, String body) {
        statusByBase.put(base, status);
        bodyByBase.put(base, body);
        return this;
    }

    /** Hace que el callout para esta moneda base "no responda a tiempo". */
    public ExchangeRateCalloutMock withTimeout(String base) {
        timeoutBases.add(base);
        return this;
    }

    /** Lo llama Salesforce en lugar de hacer el callout real. */
    public HttpResponse respond(HttpRequest request) {
        callCount++;
        endpoints.add(request.getEndpoint());

        // La URL es ".../currencies/usd.json": sacamos "usd" y lo pasamos a "USD" para buscar la configuración.
        String base = request.getEndpoint().substringAfter('/currencies/').substringBefore('.json').toUpperCase();
        if (timeoutBases.contains(base)) {
            throw new CalloutException('Read timed out');
        }

        HttpResponse response = new HttpResponse();
        response.setHeader('Content-Type', 'application/json');
        if (statusByBase.containsKey(base)) {
            response.setStatusCode(statusByBase.get(base));
            response.setBody(bodyByBase.get(base));
        } else {
            response.setStatusCode(404);
            response.setBody('{"message":"not found"}');
        }
        return response;
    }

    /** Atajo para los tests: USD con EUR 0.87889 y GBP 0.75396, publicado el 2026-09-28. */
    public static ExchangeRateCalloutMock usdDefault() {
        return new ExchangeRateCalloutMock().withRates(
            'USD',
            Date.newInstance(2026, 9, 28),
            new Map<String, Decimal>{ 'EUR' => 0.87889, 'GBP' => 0.75396 }
        );
    }
}
