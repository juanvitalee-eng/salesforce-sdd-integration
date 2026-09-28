/**
 * ErrorLogger
 *
 * Qué hace: guarda errores en el objeto ErrorLog__c ("Log de Errores") para que un administrador
 * pueda investigar después qué pasó (por ejemplo: "ayer el ERP recibió un error 500, ¿por qué?").
 *
 * Por qué existe: es un log GENÉRICO. No sabe nada del Cotizador: cualquier funcionalidad futura
 * puede usarlo pasando su propio nombre en "source" (FR-023).
 *
 * Decisiones importantes:
 * - Inserta en modo sistema (AccessLevel.SYSTEM_MODE): así un usuario sin permisos sobre el log
 *   (por ejemplo, el usuario de integración) igual puede dejar registro, pero no puede leerlo (FR-024).
 * - Recorta cada texto a su largo máximo: si un dato viene demasiado largo, preferimos guardarlo
 *   recortado antes que perder el log entero.
 * - NUNCA lanza una excepción: si guardar el log falla, no queremos que eso tape el error original.
 */
public with sharing class ErrorLogger {

    // Texto que se usa cuando un campo obligatorio del log llega vacío.
    private static final String UNKNOWN = 'Desconocido';

    /**
     * Entry: los datos de un error a registrar. Es una "ficha" simple que llena quien llama.
     */
    public class Entry {
        public String source;           // Funcionalidad que generó el error (obligatorio)
        public String channel;          // Canal por el que llegó la operación (opcional)
        public String errorCode;        // Código estable del error (obligatorio)
        public Integer statusCode;      // Código HTTP devuelto, si aplica (opcional)
        public String businessMessage;  // Mensaje claro que recibió el llamador (obligatorio)
        public String technicalDetail;  // Detalle interno para diagnóstico (opcional)
        public String relatedRecordId;  // Id del registro involucrado (opcional)
        public String context;          // Datos adicionales (opcional)
    }

    /**
     * Registra un solo error. Es un atajo de log(List<Entry>).
     */
    public static void log(Entry entry) {
        log(new List<Entry>{ entry });
    }

    /**
     * Registra una lista de errores con un único insert (bulkificado, regla 6).
     */
    public static void log(List<Entry> entries) {
        if (entries == null || entries.isEmpty()) {
            return;
        }

        // Leemos una sola vez el largo máximo de cada campo de texto, para recortar los valores.
        Integer sourceMax = Schema.SObjectType.ErrorLog__c.fields.Source__c.getLength();
        Integer channelMax = Schema.SObjectType.ErrorLog__c.fields.Channel__c.getLength();
        Integer codeMax = Schema.SObjectType.ErrorLog__c.fields.ErrorCode__c.getLength();
        Integer messageMax = Schema.SObjectType.ErrorLog__c.fields.BusinessMessage__c.getLength();
        Integer detailMax = Schema.SObjectType.ErrorLog__c.fields.TechnicalDetail__c.getLength();
        Integer recordIdMax = Schema.SObjectType.ErrorLog__c.fields.RelatedRecordId__c.getLength();
        Integer contextMax = Schema.SObjectType.ErrorLog__c.fields.Context__c.getLength();

        Datetime now = Datetime.now();
        List<ErrorLog__c> records = new List<ErrorLog__c>();
        for (Entry entry : entries) {
            if (entry == null) {
                continue;
            }
            records.add(new ErrorLog__c(
                OccurredAt__c = now,
                Source__c = fit(defaultIfBlank(entry.source), sourceMax),
                Channel__c = fit(entry.channel, channelMax),
                ErrorCode__c = fit(defaultIfBlank(entry.errorCode), codeMax),
                StatusCode__c = entry.statusCode,
                BusinessMessage__c = fit(defaultIfBlank(entry.businessMessage), messageMax),
                TechnicalDetail__c = fit(entry.technicalDetail, detailMax),
                RelatedRecordId__c = fit(entry.relatedRecordId, recordIdMax),
                Context__c = fit(entry.context, contextMax)
            ));
        }

        try {
            Database.insert(records, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            // No relanzamos: perder un log es malo, pero romper la respuesta al llamador sería peor.
            System.debug(LoggingLevel.ERROR, 'ErrorLogger no pudo guardar el log: ' + e.getMessage());
        }
    }

    /**
     * Recorta un texto para que entre en el campo. Si hay que cortar, termina en "..." para que
     * quien lo lea sepa que el valor original era más largo.
     */
    private static String fit(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.abbreviate(maxLength);
    }

    /**
     * Los campos obligatorios del log no pueden quedar vacíos: si llegan vacíos usamos "Desconocido".
     */
    private static String defaultIfBlank(String value) {
        return String.isBlank(value) ? UNKNOWN : value;
    }
}
