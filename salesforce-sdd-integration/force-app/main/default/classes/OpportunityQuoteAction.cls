/**
 * OpportunityQuoteAction
 *
 * Qué hace: es la "puerta de entrada" para el agente de Agentforce. Cuando un usuario le pide al
 * agente "cotizame la oportunidad 006... en EUR", el agente ejecuta esta acción con el Id y la moneda.
 *
 * Por qué existe: la regla 14 de la constitución dice que el agente debe reutilizar la lógica
 * existente. Esta clase NO calcula nada: solo adapta los datos y llama a OpportunityQuoteService,
 * igual que el endpoint REST. Así el agente y el sistema externo dan exactamente los mismos
 * resultados (FR-015, SC-006).
 *
 * Diferencia con el canal REST: acá los errores no se lanzan como excepción (el agente mostraría
 * un error técnico). Se devuelven como isSuccess = false con el mismo mensaje claro que recibiría
 * el sistema externo, para que el agente lo comunique sin inventar valores.
 *
 * Contrato: specs/001-opportunity-currency-quote/contracts/agent-action.md
 */
public with sharing class OpportunityQuoteAction {

    /** Lo que el agente le pasa a la acción. */
    public class Request {
        @InvocableVariable(
            label='Id de la Oportunidad'
            description='Id de la Oportunidad a cotizar (15 o 18 caracteres, empieza con 006).'
            required=true)
        public String opportunityId;

        @InvocableVariable(
            label='Moneda destino'
            description='Código de 3 letras de la moneda a la que se quiere convertir, por ejemplo EUR.'
            required=true)
        public String targetCurrency;
    }

    /** Lo que la acción le devuelve al agente. */
    public class Response {
        @InvocableVariable(label='Éxito' description='true si la cotización se realizó; false si hubo un error.')
        public Boolean isSuccess;

        @InvocableVariable(label='Mensaje' description='Resumen de la cotización o motivo del error, en lenguaje claro.')
        public String message;

        @InvocableVariable(label='Código de error' description='Código del error (solo si isSuccess es false).')
        public String errorCode;

        @InvocableVariable(label='Monto original' description='Monto de la Oportunidad en su moneda original.')
        public Decimal originalAmount;

        @InvocableVariable(label='Moneda original' description='Código de la moneda de la Oportunidad.')
        public String originalCurrency;

        @InvocableVariable(label='Moneda destino' description='Código de la moneda a la que se convirtió.')
        public String targetCurrency;

        @InvocableVariable(label='Tipo de cambio' description='Tipo de cambio aplicado (1 moneda original = X moneda destino).')
        public Decimal exchangeRate;

        @InvocableVariable(label='Monto convertido' description='Monto original por el tipo de cambio, truncado a 2 decimales.')
        public Decimal convertedAmount;

        @InvocableVariable(label='Fecha/hora de cotización' description='Momento de la cotización en formato ISO 8601 UTC.')
        public String quotedAt;
    }

    /**
     * Ejecuta la cotización. Recibe una lista porque así lo exige Salesforce para las acciones
     * invocables (bulkificación); el agente normalmente manda un solo pedido.
     */
    @InvocableMethod(
        label='Cotizar Oportunidad en otra moneda'
        description='Cotiza el monto de una Oportunidad en otra moneda con el tipo de cambio del día y guarda la cotización en el historial.')
    public static List<Response> quote(List<Request> requests) {
        // Adaptamos los datos del agente al formato que entiende el Service.
        List<QuoteModels.QuoteRequest> quoteRequests = new List<QuoteModels.QuoteRequest>();
        for (Request request : requests) {
            QuoteModels.QuoteRequest quoteRequest = new QuoteModels.QuoteRequest();
            quoteRequest.opportunityId = request.opportunityId;
            quoteRequest.targetCurrency = request.targetCurrency;
            quoteRequests.add(quoteRequest);
        }

        List<Response> responses = new List<Response>();
        try {
            // Una sola llamada al Service para toda la lista (misma lógica que el canal REST).
            for (QuoteModels.QuoteResult result : OpportunityQuoteService.quote(quoteRequests, OpportunityQuoteService.CHANNEL_AGENT)) {
                responses.add(toSuccess(result));
            }
        } catch (QuoteException e) {
            // "Todo o nada": si falla, todos los pedidos reciben el mismo error, sin valores numéricos.
            for (Integer i = 0; i < requests.size(); i++) {
                responses.add(toFailure(e));
            }
        }
        return responses;
    }

    /** Arma la respuesta de éxito con los 6 datos y un resumen legible para el agente. */
    private static Response toSuccess(QuoteModels.QuoteResult result) {
        Response response = new Response();
        response.isSuccess = true;
        response.originalAmount = result.originalAmount;
        response.originalCurrency = result.originalCurrency;
        response.targetCurrency = result.targetCurrency;
        response.exchangeRate = result.exchangeRate;
        response.convertedAmount = result.convertedAmount;
        // JSON.serialize da el mismo formato ISO 8601 UTC que ve el sistema externo.
        response.quotedAt = JSON.serialize(result.quotedAt).remove('"');
        response.message = 'La Oportunidad ' + result.opportunityId + ' tiene un monto de '
            + result.originalAmount.setScale(2) + ' ' + result.originalCurrency + ', que equivale a '
            + result.convertedAmount + ' ' + result.targetCurrency + ' con un tipo de cambio de '
            + result.exchangeRate + ' (cotización del ' + response.quotedAt + ', UTC).';
        return response;
    }

    /** Arma la respuesta de error con el mismo mensaje que recibiría el sistema externo. */
    private static Response toFailure(QuoteException error) {
        Response response = new Response();
        response.isSuccess = false;
        response.errorCode = error.errorCode;
        response.message = error.getMessage();
        return response;
    }
}
