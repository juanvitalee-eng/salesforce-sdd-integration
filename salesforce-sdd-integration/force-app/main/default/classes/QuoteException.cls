/**
 * QuoteException
 *
 * Qué hace: es el "tipo de error" propio del Cotizador de Oportunidades (regla 8 de la constitución).
 * Además del mensaje, lleva los datos que necesitamos para responderle bien al llamador:
 * un código estable (errorCode), el código HTTP (400 o 500), qué pedido falló y su Id.
 *
 * Por qué es "virtual": para que existan dos variantes más específicas que heredan de ésta:
 * - QuoteValidationException: el problema está en el pedido del llamador (HTTP 400).
 * - ExchangeRateUnavailableException: el proveedor de tipo de cambio no respondió bien (HTTP 500).
 *
 * El mensaje (getMessage) SIEMPRE es un texto claro para una persona de negocio.
 * Los detalles técnicos van aparte, en technicalDetail, y nunca se muestran al llamador (FR-008).
 */
public virtual with sharing class QuoteException extends Exception {

    // Catálogo de códigos de error (ver data-model.md). Son estables: el ERP puede depender de ellos.
    public static final String INVALID_REQUEST_BODY = 'INVALID_REQUEST_BODY';
    public static final String EMPTY_REQUEST_LIST = 'EMPTY_REQUEST_LIST';
    public static final String REQUEST_LIMIT_EXCEEDED = 'REQUEST_LIMIT_EXCEEDED';
    public static final String INVALID_OPPORTUNITY_ID = 'INVALID_OPPORTUNITY_ID';
    public static final String OPPORTUNITY_NOT_FOUND = 'OPPORTUNITY_NOT_FOUND';
    public static final String OPPORTUNITY_WITHOUT_AMOUNT = 'OPPORTUNITY_WITHOUT_AMOUNT';
    public static final String INVALID_CURRENCY_CODE = 'INVALID_CURRENCY_CODE';
    public static final String UNSUPPORTED_CURRENCY = 'UNSUPPORTED_CURRENCY';
    public static final String EXCHANGE_RATE_UNAVAILABLE = 'EXCHANGE_RATE_UNAVAILABLE';
    public static final String INTERNAL_ERROR = 'INTERNAL_ERROR';

    // Mensajes genéricos para los errores del servicio (500).
    public static final String MESSAGE_UNAVAILABLE =
        'El tipo de cambio no está disponible en este momento. Intente nuevamente más tarde.';
    public static final String MESSAGE_INTERNAL =
        'Ocurrió un error inesperado al procesar la cotización.';

    public String errorCode;        // Código del catálogo de arriba
    public Integer httpStatus;      // 400 (pedido inválido) o 500 (error del servicio)
    public Integer requestIndex;    // Posición del pedido que falló, empezando en 1 (null = toda la llamada)
    public String opportunityId;    // Id tal como vino en el pedido que falló (null si no aplica)
    public String technicalDetail;  // Detalle interno para el log; nunca se devuelve al llamador

    /**
     * Crea un error de pedido inválido (HTTP 400).
     */
    public static QuoteException validation(String code, String message, Integer requestIndex, String opportunityId) {
        QuoteException error = new QuoteValidationException(message);
        error.errorCode = code;
        error.httpStatus = 400;
        return error.atRequest(requestIndex, opportunityId);
    }

    /**
     * Crea un error de "tipo de cambio no disponible" (HTTP 500).
     */
    public static QuoteException unavailable(String technicalDetail) {
        QuoteException error = new ExchangeRateUnavailableException(MESSAGE_UNAVAILABLE);
        error.errorCode = EXCHANGE_RATE_UNAVAILABLE;
        error.httpStatus = 500;
        error.technicalDetail = technicalDetail;
        return error;
    }

    /**
     * Crea un error inesperado (HTTP 500). Se usa cuando algo falla y no es un caso previsto.
     */
    public static QuoteException internal(String technicalDetail) {
        QuoteException error = new QuoteException(MESSAGE_INTERNAL);
        error.errorCode = INTERNAL_ERROR;
        error.httpStatus = 500;
        error.technicalDetail = technicalDetail;
        return error;
    }

    /**
     * Indica a qué pedido corresponde el error (posición e Id). Devuelve el mismo error,
     * para poder encadenarlo: QuoteException.unavailable(...).atRequest(2, '006...').
     */
    public QuoteException atRequest(Integer requestIndex, String opportunityId) {
        this.requestIndex = requestIndex;
        this.opportunityId = opportunityId;
        return this;
    }
}
