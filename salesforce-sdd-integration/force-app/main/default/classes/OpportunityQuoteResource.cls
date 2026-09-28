/**
 * OpportunityQuoteResource
 *
 * Qué hace: es la "puerta de entrada" REST para sistemas externos (ERP/CRM).
 *   POST /services/apexrest/v1/opportunity-quotes
 * Recibe el JSON, se lo pasa al Service y devuelve la respuesta con el código HTTP correcto:
 *   200 = todo OK, 400 = el pedido tiene un problema, 500 = falló el servicio.
 *
 * Por qué existe: la regla 4 de la constitución separa las capas. Esta clase SOLO se ocupa de HTTP
 * (leer el body, armar la respuesta). Toda la lógica de negocio está en OpportunityQuoteService.
 *
 * Contrato completo: specs/001-opportunity-currency-quote/contracts/opportunity-quotes-api.md
 */
@RestResource(urlMapping='/v1/opportunity-quotes')
global with sharing class OpportunityQuoteResource {

    private static final String INVALID_BODY_MESSAGE = 'El cuerpo del pedido no tiene el formato esperado.';

    /**
     * Atiende el POST. No devuelve nada directamente: escribe la respuesta en RestContext.response.
     */
    @HttpPost
    global static void quote() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        try {
            QuoteModels.BatchRequest body = parseBody(RestContext.request);
            List<QuoteModels.QuoteResult> quotes =
                OpportunityQuoteService.quote(body.requests, OpportunityQuoteService.CHANNEL_EXTERNAL);

            QuoteModels.BatchResponse success = new QuoteModels.BatchResponse();
            success.quotes = quotes;
            response.statusCode = 200;
            response.responseBody = Blob.valueOf(JSON.serialize(success));
        } catch (QuoteException e) {
            // Error previsto: el Service ya lo registró en el log. Solo armamos la respuesta.
            writeError(response, e);
        } catch (Exception e) {
            // Red de seguridad: nunca devolver una excepción cruda al llamador (regla 8, FR-008).
            QuoteException internal = QuoteException.internal(e.getTypeName() + ': ' + e.getMessage());
            OpportunityQuoteService.logRejection(internal, OpportunityQuoteService.CHANNEL_EXTERNAL, 0);
            writeError(response, internal);
        }
    }

    /**
     * Convierte el JSON recibido en un BatchRequest tipado (regla 7). Si el JSON está mal formado o
     * no trae "requests", responde 400 INVALID_REQUEST_BODY y deja registro en el log.
     */
    private static QuoteModels.BatchRequest parseBody(RestRequest request) {
        QuoteModels.BatchRequest body;
        String technicalDetail;
        try {
            String rawBody = request.requestBody == null ? '' : request.requestBody.toString();
            body = (QuoteModels.BatchRequest) JSON.deserialize(rawBody, QuoteModels.BatchRequest.class);
        } catch (Exception e) {
            technicalDetail = e.getTypeName() + ': ' + e.getMessage();
        }

        if (body == null || body.requests == null) {
            QuoteException error = QuoteException.validation(
                QuoteException.INVALID_REQUEST_BODY, INVALID_BODY_MESSAGE, null, null);
            error.technicalDetail = technicalDetail == null ? 'Falta la propiedad "requests".' : technicalDetail;
            OpportunityQuoteService.logRejection(error, OpportunityQuoteService.CHANNEL_EXTERNAL, 0);
            throw error;
        }
        return body;
    }

    /**
     * Escribe la respuesta de error: el código HTTP del error y un JSON sin detalles técnicos.
     */
    private static void writeError(RestResponse response, QuoteException error) {
        response.statusCode = error.httpStatus;
        response.responseBody = Blob.valueOf(JSON.serialize(QuoteModels.toErrorResponse(error)));
    }
}
