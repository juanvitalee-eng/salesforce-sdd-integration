/**
 * ExchangeRateClient
 *
 * Qué hace: es el ÚNICO lugar del sistema que habla con el proveedor de tipo de cambio (Frankfurter).
 * Le pide, para cada moneda base, todas sus tasas del día.
 *
 * Por qué existe: la regla 4 de la constitución pide una clase dedicada exclusivamente a cada
 * callout externo. Si mañana cambiamos de proveedor, solo se toca esta clase.
 *
 * Cómo funciona (research.md §1):
 * - Hace UN callout por moneda base (no uno por pedido): GET callout:FrankfurterApi/latest?base=USD
 *   y la respuesta trae las tasas contra todas las demás monedas.
 * - 200 → tabla de tasas. 404 → el proveedor no soporta esa moneda base.
 * - Cualquier otra cosa (timeout, 500, respuesta ilegible) → ExchangeRateUnavailableException.
 */
public with sharing class ExchangeRateClient {

    /**
     * RateTable: las tasas de una moneda base, tal como las informó el proveedor.
     */
    public class RateTable {
        public String baseCurrency;         // Ej. "USD"
        public Boolean isSupported;         // false si el proveedor no conoce esta moneda
        public Date rateDate;               // Fecha de publicación de las tasas
        public Map<String, Decimal> rates;  // Ej. {"EUR": 0.87889, "GBP": 0.75396}
        public Datetime fetchedAt;          // Momento en que obtuvimos las tasas
    }

    /**
     * Molde tipado de la respuesta de Frankfurter:
     * {"amount":1.0,"base":"USD","date":"2026-09-28","rates":{"EUR":0.87889,...}}
     * Nota: "date" es una palabra reservada en Apex, por eso la renombramos a "rateDate" antes de leer.
     */
    private class ProviderResponse {
        public String base;
        public Date rateDate;
        public Map<String, Decimal> rates;
    }

    /**
     * Obtiene las tasas para cada moneda base pedida. Devuelve un mapa moneda base → tabla de tasas.
     * Lanza ExchangeRateUnavailableException si el proveedor no está disponible.
     */
    public static Map<String, RateTable> getRates(Set<String> baseCurrencies) {
        Map<String, RateTable> tablesByBase = new Map<String, RateTable>();
        if (baseCurrencies == null || baseCurrencies.isEmpty()) {
            return tablesByBase;
        }

        String namedCredential = OpportunityQuoteSettings.namedCredentialName();
        Integer timeoutMs = OpportunityQuoteSettings.calloutTimeoutMs();

        // Un callout por moneda base. No hay SOQL ni DML en este loop (regla 6); el número de
        // monedas base está limitado por las monedas activas de la org.
        for (String baseCurrency : baseCurrencies) {
            tablesByBase.put(baseCurrency, fetchRates(baseCurrency, namedCredential, timeoutMs));
        }
        return tablesByBase;
    }

    /**
     * Hace el callout para una moneda base y traduce la respuesta a una RateTable.
     */
    private static RateTable fetchRates(String baseCurrency, String namedCredential, Integer timeoutMs) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + namedCredential + '/latest?base=' + EncodingUtil.urlEncode(baseCurrency, 'UTF-8'));
        request.setMethod('GET');
        request.setTimeout(timeoutMs);

        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            // Incluye el timeout: el proveedor no respondió a tiempo.
            throw QuoteException.unavailable('Callout para base ' + baseCurrency + ' falló: ' + e.getMessage());
        }

        RateTable table = new RateTable();
        table.baseCurrency = baseCurrency;

        Integer status = response.getStatusCode();
        if (status == 404) {
            // Frankfurter responde 404 cuando no conoce la moneda base (ej. ARS).
            table.isSupported = false;
            table.rates = new Map<String, Decimal>();
            return table;
        }
        if (status != 200) {
            throw QuoteException.unavailable('HTTP ' + status + ' para base ' + baseCurrency + ': ' + response.getBody());
        }

        ProviderResponse parsed;
        try {
            String body = response.getBody().replace('"date":', '"rateDate":');
            parsed = (ProviderResponse) JSON.deserialize(body, ProviderResponse.class);
        } catch (Exception e) {
            throw QuoteException.unavailable('Respuesta ilegible para base ' + baseCurrency + ': ' + e.getMessage());
        }
        if (parsed == null || parsed.rates == null || parsed.rateDate == null) {
            throw QuoteException.unavailable('Respuesta incompleta para base ' + baseCurrency + ': ' + response.getBody());
        }

        table.isSupported = true;
        table.rateDate = parsed.rateDate;
        table.rates = parsed.rates;
        table.fetchedAt = Datetime.now();
        return table;
    }
}
