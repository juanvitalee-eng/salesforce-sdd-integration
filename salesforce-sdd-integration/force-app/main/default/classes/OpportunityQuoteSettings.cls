/**
 * OpportunityQuoteSettings
 *
 * Qué hace: lee la configuración del Cotizador desde el Custom Metadata
 * OpportunityQuoteSetting__mdt (registro "Default").
 *
 * Por qué existe: la regla 10 de la constitución prohíbe escribir valores de configuración en el
 * código. Así, un administrador puede cambiar el máximo de pedidos o el timeout desde Setup, sin
 * desplegar código.
 *
 * Si el registro no existe, usa valores por defecto razonables para que nada se rompa.
 */
public with sharing class OpportunityQuoteSettings {

    private static final String RECORD_NAME = 'Default';
    private static final Integer DEFAULT_MAX_REQUESTS = 200;
    private static final Integer DEFAULT_TIMEOUT_MS = 10000;
    private static final String DEFAULT_NAMED_CREDENTIAL = 'CurrencyApi';

    // Solo para tests: permite simular otra configuración sin tocar la de la org.
    @TestVisible
    private static OpportunityQuoteSetting__mdt testOverride;

    // Solo para tests: permite simular otra lista de monedas habilitadas.
    @TestVisible
    private static Set<String> enabledCurrenciesOverride;

    /**
     * Monedas que el Cotizador acepta (FR-025): los códigos ISO de los registros ACTIVOS de
     * QuoteCurrency__mdt ("Moneda del Cotizador"). Un administrador las edita desde Setup.
     * getAll() lee el Custom Metadata sin gastar consultas SOQL.
     */
    public static Set<String> enabledCurrencies() {
        if (enabledCurrenciesOverride != null) {
            return enabledCurrenciesOverride;
        }
        Set<String> codes = new Set<String>();
        for (QuoteCurrency__mdt quoteCurrency : QuoteCurrency__mdt.getAll().values()) {
            if (quoteCurrency.IsActive__c) {
                codes.add(quoteCurrency.DeveloperName.toUpperCase());
            }
        }
        return codes;
    }

    /** Cantidad máxima de pedidos aceptados en una llamada (FR-004). */
    public static Integer maxRequestsPerCall() {
        OpportunityQuoteSetting__mdt setting = current();
        if (setting == null || setting.MaxRequestsPerCall__c == null) {
            return DEFAULT_MAX_REQUESTS;
        }
        return setting.MaxRequestsPerCall__c.intValue();
    }

    /** Tiempo máximo de espera al proveedor, en milisegundos. */
    public static Integer calloutTimeoutMs() {
        OpportunityQuoteSetting__mdt setting = current();
        if (setting == null || setting.CalloutTimeoutMs__c == null) {
            return DEFAULT_TIMEOUT_MS;
        }
        return setting.CalloutTimeoutMs__c.intValue();
    }

    /** Nombre de la Named Credential que apunta al proveedor de tipo de cambio. */
    public static String namedCredentialName() {
        OpportunityQuoteSetting__mdt setting = current();
        if (setting == null || String.isBlank(setting.NamedCredentialName__c)) {
            return DEFAULT_NAMED_CREDENTIAL;
        }
        return setting.NamedCredentialName__c;
    }

    /** Devuelve la configuración vigente: la de test si existe, si no la de la org. */
    private static OpportunityQuoteSetting__mdt current() {
        if (testOverride != null) {
            return testOverride;
        }
        return OpportunityQuoteSetting__mdt.getInstance(RECORD_NAME);
    }
}
