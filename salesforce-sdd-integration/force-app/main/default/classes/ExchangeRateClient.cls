/**
 * ExchangeRateClient
 *
 * Qué hace: es el ÚNICO lugar del sistema que habla con el proveedor de tipo de cambio (currency-api).
 * Le pide, para cada moneda base, todas sus tasas del día.
 *
 * Por qué existe: la regla 4 de la constitución pide una clase dedicada exclusivamente a cada
 * callout externo. Gracias a eso, cuando cambiamos de Frankfurter a currency-api (porque Frankfurter
 * no publica ARS) solo se tocó esta clase: el resto del sistema no se enteró.
 *
 * Cómo funciona (research.md §1):
 * - Hace UN callout por moneda base (no uno por pedido): GET callout:CurrencyApi/currencies/usd.json
 *   y la respuesta trae las tasas contra todas las demás monedas.
 * - El proveedor usa códigos en minúsculas ("usd"); nosotros trabajamos siempre en MAYÚSCULAS ("USD").
 * - 200 → tabla de tasas. 404 → el proveedor no publica esa moneda base.
 * - Cualquier otra cosa (timeout, 500, respuesta ilegible) → ExchangeRateUnavailableException.
 */
public with sharing class ExchangeRateClient {

    /**
     * RateTable: las tasas de una moneda base, tal como las informó el proveedor.
     */
    public class RateTable {
        public String baseCurrency;         // Ej. "USD"
        public Boolean isSupported;         // false si el proveedor no publica esta moneda
        public Date rateDate;               // Fecha de publicación de las tasas
        public Map<String, Decimal> rates;  // Ej. {"EUR": 0.87803741, "ARS": 1521.76514116}
        public Datetime fetchedAt;          // Momento en que obtuvimos las tasas
    }

    /**
     * Molde tipado de la respuesta de currency-api:
     *   {"date":"2026-09-28","usd":{"ars":1521.76514116,"eur":0.87803741,...}}
     * Dos detalles:
     * - "date" es una palabra reservada en Apex, por eso la renombramos a "rateDate" antes de leer.
     * - La clave del mapa de tasas es la propia moneda base ("usd", "ars", ...), así que cambia en cada
     *   llamada. La renombramos a "rates" para poder leerla siempre con el mismo molde.
     */
    private class ProviderResponse {
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
        String providerCode = baseCurrency.toLowerCase(); // El proveedor responde 404 si va en mayúsculas

        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + namedCredential + '/currencies/'
            + EncodingUtil.urlEncode(providerCode, 'UTF-8') + '.json');
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
            // El proveedor responde 404 cuando no publica la moneda base.
            table.isSupported = false;
            table.rates = new Map<String, Decimal>();
            return table;
        }
        if (status != 200) {
            throw QuoteException.unavailable('HTTP ' + status + ' para base ' + baseCurrency + ': ' + response.getBody());
        }

        ProviderResponse parsed;
        try {
            // replaceFirst: solo la PRIMERA aparición, que es la clave de afuera. Adentro del mapa de
            // tasas también aparece la moneda base (ej. "usd": 1) y esa no hay que tocarla.
            String body = response.getBody()
                .replaceFirst('"date"\\s*:', '"rateDate":')
                .replaceFirst('"' + providerCode + '"\\s*:', '"rates":');
            parsed = (ProviderResponse) JSON.deserialize(body, ProviderResponse.class);
        } catch (Exception e) {
            throw QuoteException.unavailable('Respuesta ilegible para base ' + baseCurrency + ': ' + e.getMessage());
        }
        if (parsed == null || parsed.rates == null || parsed.rateDate == null) {
            throw QuoteException.unavailable('Respuesta incompleta para base ' + baseCurrency + ': ' + response.getBody());
        }

        table.isSupported = true;
        table.rateDate = parsed.rateDate;
        table.rates = toUpperCaseKeys(parsed.rates);
        table.fetchedAt = Datetime.now();
        return table;
    }

    /**
     * Pasa las claves del proveedor ("eur") a códigos ISO en mayúsculas ("EUR"), que es como las usa
     * el resto del sistema.
     */
    private static Map<String, Decimal> toUpperCaseKeys(Map<String, Decimal> providerRates) {
        Map<String, Decimal> rates = new Map<String, Decimal>();
        for (String code : providerRates.keySet()) {
            rates.put(code.toUpperCase(), providerRates.get(code));
        }
        return rates;
    }
}
