/**
 * QuoteModels
 *
 * Qué hace: define la "forma" exacta de los datos que entran y salen del Cotizador por REST
 * (ver contracts/opportunity-quotes-api.md). Cada clase interna es un "molde" tipado.
 *
 * Por qué existe: la regla 7 de la constitución pide usar clases tipadas en lugar de mapas sueltos.
 * Así, si alguien escribe mal un nombre de campo, el error aparece al compilar y no en producción.
 *
 * IMPORTANTE: los nombres de las propiedades son los mismos que ve el sistema externo en el JSON.
 * Cambiarlos rompe el contrato con el ERP.
 */
public with sharing class QuoteModels {

    /** Un pedido de cotización: qué Oportunidad y a qué moneda. */
    public class QuoteRequest {
        public String opportunityId;
        public String targetCurrency;
    }

    /** Lo que envía el sistema externo en el body del POST: una lista de pedidos. */
    public class BatchRequest {
        public List<QuoteRequest> requests;
    }

    /** Una cotización exitosa. */
    public class QuoteResult {
        public String opportunityId;
        public Decimal originalAmount;
        public String originalCurrency;
        public String targetCurrency;
        public Decimal exchangeRate;
        public Decimal convertedAmount;
        public Datetime quotedAt;   // Se envía en formato ISO 8601 UTC (ej. 2026-09-28T14:03:12.000Z)
        public Date rateDate;       // Fecha en que el proveedor publicó la tasa (ej. 2026-09-28)
    }

    /** Respuesta 200: una cotización por pedido, en el mismo orden. */
    public class BatchResponse {
        public List<QuoteResult> quotes;
    }

    /** Respuesta 400/500: un único error que explica por qué se rechazó la llamada. */
    public class ErrorResponse {
        public ErrorDetail error;
    }

    /** Detalle del error. Nunca incluye información técnica interna (FR-008). */
    public class ErrorDetail {
        public String code;
        public String message;
        public Integer requestIndex;
        public String opportunityId;
    }

    /**
     * Arma la respuesta de error a partir de un QuoteException. Toma solo los datos públicos:
     * el detalle técnico queda afuera a propósito.
     */
    public static ErrorResponse toErrorResponse(QuoteException error) {
        ErrorDetail detail = new ErrorDetail();
        detail.code = error.errorCode;
        detail.message = error.getMessage();
        detail.requestIndex = error.requestIndex;
        detail.opportunityId = error.opportunityId;

        ErrorResponse response = new ErrorResponse();
        response.error = detail;
        return response;
    }
}
