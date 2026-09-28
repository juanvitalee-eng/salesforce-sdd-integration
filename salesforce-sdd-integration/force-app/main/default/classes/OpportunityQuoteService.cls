/**
 * OpportunityQuoteService
 *
 * Qué hace: es el "cerebro" del Cotizador de Oportunidades. Recibe una lista de pedidos
 * (Id de Oportunidad + moneda destino), calcula cada cotización con el tipo de cambio del día y,
 * si TODO salió bien, guarda una cotización histórica (CurrencyQuote__c) por cada pedido.
 *
 * Por qué existe: es la ÚNICA lógica de cotización del sistema. La usan los dos canales
 * (el endpoint REST y la acción del agente de Agentforce), así ambos dan exactamente los mismos
 * resultados (FR-015, regla 14 de la constitución).
 *
 * Reglas clave:
 * - "Todo o nada" (FR-010): si falla cualquier pedido, se rechaza la lista entera, no se devuelve
 *   ninguna cotización y no se guarda ninguna.
 * - Si fallan varios pedidos, se informa el de MENOR posición (research.md §3). Para eso se evalúan
 *   todos los pedidos antes de decidir, en vez de cortar en el primer problema que aparezca.
 * - Toda llamada rechazada deja exactamente un registro en el Log de Errores (FR-021, SC-009).
 * - La Oportunidad nunca se modifica (FR-019, regla 12).
 * - Los callouts se hacen antes de cualquier DML (regla 5).
 *
 * Etapas (research.md §3):
 *   1. Validar la lista (vacía, demasiados pedidos).
 *   2. Validar el formato de cada pedido (Id y moneda).
 *   3. Leer las Oportunidades con UNA sola consulta.
 *   4. Pedir los tipos de cambio: un callout por moneda original distinta.
 *   5. Calcular cada cotización.
 *   6. Si no hubo errores, guardar todas las cotizaciones con UN solo insert.
 */
public with sharing class OpportunityQuoteService {

    // Canales de origen (coinciden con los valores del picklist CurrencyQuote__c.Channel__c).
    public static final String CHANNEL_EXTERNAL = 'ExternalSystem';
    public static final String CHANNEL_AGENT = 'Agent';

    // Nombre con el que esta funcionalidad se identifica en el Log de Errores.
    public static final String SOURCE = 'Cotizador de Oportunidades';

    // Un código de moneda válido son exactamente 3 letras (ISO 4217), ej. "EUR".
    private static final Pattern CURRENCY_CODE_PATTERN = Pattern.compile('^[A-Za-z]{3}$');

    /**
     * Cotiza una lista de pedidos. Devuelve una cotización por pedido, en el mismo orden (FR-003).
     * Si algo falla, registra el error en el log y lanza un QuoteException con un mensaje claro.
     *
     * @param requests  los pedidos a cotizar
     * @param channel   CHANNEL_EXTERNAL o CHANNEL_AGENT (queda guardado en cada cotización)
     */
    public static List<QuoteModels.QuoteResult> quote(List<QuoteModels.QuoteRequest> requests, String channel) {
        Integer totalRequests = requests == null ? 0 : requests.size();
        try {
            return process(requests, channel);
        } catch (QuoteException e) {
            // Error previsto (400 o 500): lo registramos y lo pasamos al canal para que responda.
            logRejection(e, channel, totalRequests);
            throw e;
        } catch (Exception e) {
            // Error no previsto: nunca dejamos escapar una excepción genérica (regla 8).
            // Al llamador le llega un mensaje genérico; el detalle técnico queda solo en el log.
            QuoteException internal = QuoteException.internal(
                e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
            logRejection(internal, channel, totalRequests);
            throw internal;
        }
    }

    /**
     * Registra en el Log de Errores una llamada rechazada. Es público porque el endpoint REST
     * también lo usa cuando el body llega mal formado (antes de llegar a este Service).
     */
    public static void logRejection(QuoteException error, String channel, Integer totalRequests) {
        ErrorLogger.Entry entry = new ErrorLogger.Entry();
        entry.source = SOURCE;
        entry.channel = channel;
        entry.errorCode = error.errorCode;
        entry.statusCode = error.httpStatus;
        entry.businessMessage = error.getMessage();
        entry.technicalDetail = error.technicalDetail;
        // Solo guardamos el Id si es un Id real de Salesforce; si no, el valor crudo va en el contexto.
        entry.relatedRecordId = isSalesforceId(error.opportunityId) ? error.opportunityId : null;
        entry.context = error.requestIndex == null
            ? 'Llamada con ' + totalRequests + ' pedido(s).'
            : 'Pedido ' + error.requestIndex + ' de ' + totalRequests + ', Id recibido: ' + error.opportunityId;
        ErrorLogger.log(entry);
    }

    // ---------------------------------------------------------------------------------------------
    // Proceso principal
    // ---------------------------------------------------------------------------------------------

    private static List<QuoteModels.QuoteResult> process(List<QuoteModels.QuoteRequest> requests, String channel) {
        // Etapa 1: problemas de la lista entera. Estos cortan de inmediato.
        validateBatch(requests);

        Integer total = requests.size();

        // Todos los mapas usan como clave la POSICIÓN del pedido, empezando en 1.
        Map<Integer, QuoteException> errorsByPosition = new Map<Integer, QuoteException>();
        Map<Integer, Id> opportunityIdByPosition = new Map<Integer, Id>();
        Map<Integer, String> targetCurrencyByPosition = new Map<Integer, String>();

        // Monedas que un administrador habilitó para el Cotizador (FR-025).
        Set<String> enabledCurrencies = OpportunityQuoteSettings.enabledCurrencies();

        // Etapa 2: formato de cada pedido. No cortamos: anotamos el error y seguimos.
        for (Integer position = 1; position <= total; position++) {
            QuoteModels.QuoteRequest request = requests[position - 1];
            String rawId = request == null ? null : request.opportunityId;
            String rawCurrency = request == null ? null : request.targetCurrency;

            Id opportunityId = toOpportunityId(rawId);
            if (opportunityId == null) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.INVALID_OPPORTUNITY_ID,
                    requestPrefix(position, rawId) + 'el Id no es un Id de Oportunidad válido.',
                    position, rawId));
                continue;
            }
            if (String.isBlank(rawCurrency) || !CURRENCY_CODE_PATTERN.matcher(rawCurrency.trim()).matches()) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.INVALID_CURRENCY_CODE,
                    requestPrefix(position, rawId) + '"' + rawCurrency
                        + '" no es un código de moneda válido (use 3 letras, por ejemplo EUR).',
                    position, rawId));
                continue;
            }
            String targetCurrency = rawCurrency.trim().toUpperCase(); // "eur" → "EUR"
            if (!enabledCurrencies.contains(targetCurrency)) {
                // Se rechaza acá, antes de consultar al proveedor (FR-026).
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.UNSUPPORTED_CURRENCY,
                    requestPrefix(position, rawId) + 'la moneda destino ' + targetCurrency
                        + ' no está habilitada en el Cotizador.',
                    position, rawId));
                continue;
            }
            opportunityIdByPosition.put(position, opportunityId);
            targetCurrencyByPosition.put(position, targetCurrency);
        }

        // Etapa 3: leer las Oportunidades (una sola consulta, respetando los permisos del usuario).
        Map<Integer, Opportunity> opportunityByPosition =
            loadOpportunities(requests, opportunityIdByPosition, errorsByPosition, enabledCurrencies);

        // Etapas 4 y 5: tipos de cambio y cálculo.
        Map<Integer, QuoteModels.QuoteResult> resultByPosition =
            calculateQuotes(requests, opportunityByPosition, targetCurrencyByPosition, errorsByPosition);

        // Si hubo errores, se rechaza todo y se informa el de menor posición (FR-010).
        if (!errorsByPosition.isEmpty()) {
            throw errorsByPosition.get(lowestPosition(errorsByPosition.keySet()));
        }

        // Armamos la respuesta en el mismo orden en que llegaron los pedidos (FR-003).
        List<QuoteModels.QuoteResult> results = new List<QuoteModels.QuoteResult>();
        for (Integer position = 1; position <= total; position++) {
            results.add(resultByPosition.get(position));
        }

        // Etapa 6: guardar el historial. Siempre después de los callouts (regla 5).
        saveQuotes(results, opportunityByPosition, channel);
        return results;
    }

    /**
     * Etapa 1: la lista no puede venir vacía ni superar el máximo configurado (FR-004).
     */
    private static void validateBatch(List<QuoteModels.QuoteRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            throw QuoteException.validation(QuoteException.EMPTY_REQUEST_LIST,
                'Debe enviar al menos un pedido de cotización.', null, null);
        }
        Integer maxRequests = OpportunityQuoteSettings.maxRequestsPerCall();
        if (requests.size() > maxRequests) {
            throw QuoteException.validation(QuoteException.REQUEST_LIMIT_EXCEEDED,
                'Se pueden enviar como máximo ' + maxRequests + ' pedidos por llamada (se recibieron '
                    + requests.size() + ').', null, null);
        }
    }

    /**
     * Etapa 3: lee las Oportunidades con UNA consulta (nunca SOQL dentro de un loop, regla 6).
     * WITH USER_MODE hace que se respeten los permisos del usuario: si no puede ver una
     * Oportunidad, para nosotros "no existe" (sin revelar que existe, FR-005).
     * También rechaza las Oportunidades cuya moneda no está habilitada, antes de cualquier callout.
     * Devuelve las Oportunidades listas para cotizar, por posición.
     */
    private static Map<Integer, Opportunity> loadOpportunities(
        List<QuoteModels.QuoteRequest> requests,
        Map<Integer, Id> opportunityIdByPosition,
        Map<Integer, QuoteException> errorsByPosition,
        Set<String> enabledCurrencies
    ) {
        Map<Integer, Opportunity> opportunityByPosition = new Map<Integer, Opportunity>();
        if (opportunityIdByPosition.isEmpty()) {
            return opportunityByPosition;
        }

        Set<Id> ids = new Set<Id>(opportunityIdByPosition.values());
        Map<Id, Opportunity> opportunitiesById = new Map<Id, Opportunity>(
            [SELECT Id, Amount, CurrencyIsoCode FROM Opportunity WHERE Id IN :ids WITH USER_MODE]
        );

        for (Integer position : opportunityIdByPosition.keySet()) {
            String rawId = requests[position - 1].opportunityId;
            Opportunity opportunity = opportunitiesById.get(opportunityIdByPosition.get(position));
            if (opportunity == null) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.OPPORTUNITY_NOT_FOUND,
                    requestPrefix(position, rawId) + 'la Oportunidad indicada no existe.',
                    position, rawId));
            } else if (opportunity.Amount == null) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.OPPORTUNITY_WITHOUT_AMOUNT,
                    requestPrefix(position, rawId) + 'la Oportunidad no tiene monto para cotizar.',
                    position, rawId));
            } else if (!enabledCurrencies.contains(opportunity.CurrencyIsoCode)) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.UNSUPPORTED_CURRENCY,
                    requestPrefix(position, rawId) + 'la moneda original ' + opportunity.CurrencyIsoCode
                        + ' no está habilitada en el Cotizador.',
                    position, rawId));
            } else {
                opportunityByPosition.put(position, opportunity);
            }
        }
        return opportunityByPosition;
    }

    /**
     * Etapas 4 y 5: pide los tipos de cambio y calcula cada cotización.
     */
    private static Map<Integer, QuoteModels.QuoteResult> calculateQuotes(
        List<QuoteModels.QuoteRequest> requests,
        Map<Integer, Opportunity> opportunityByPosition,
        Map<Integer, String> targetCurrencyByPosition,
        Map<Integer, QuoteException> errorsByPosition
    ) {
        Map<Integer, QuoteModels.QuoteResult> resultByPosition = new Map<Integer, QuoteModels.QuoteResult>();

        // Si ya hay un error en la posición N, los pedidos posteriores no pueden cambiar el resultado
        // (siempre se informa el de menor posición). Solo cotizamos los que están antes de N.
        Integer firstError = errorsByPosition.isEmpty() ? null : lowestPosition(errorsByPosition.keySet());
        List<Integer> positionsToQuote = new List<Integer>();
        Set<String> baseCurrencies = new Set<String>();
        for (Integer position : opportunityByPosition.keySet()) {
            if (firstError == null || position < firstError) {
                positionsToQuote.add(position);
                baseCurrencies.add(opportunityByPosition.get(position).CurrencyIsoCode);
            }
        }
        if (positionsToQuote.isEmpty()) {
            return resultByPosition;
        }

        // Etapa 4: un callout por moneda original distinta (no uno por pedido).
        Map<String, ExchangeRateClient.RateTable> tablesByBase;
        QuoteException providerError;
        try {
            tablesByBase = ExchangeRateClient.getRates(baseCurrencies);
        } catch (ExchangeRateUnavailableException e) {
            providerError = e;
        }

        // Etapa 5: calcular cada cotización.
        for (Integer position : positionsToQuote) {
            String rawId = requests[position - 1].opportunityId;
            Opportunity opportunity = opportunityByPosition.get(position);
            String originalCurrency = opportunity.CurrencyIsoCode;
            String targetCurrency = targetCurrencyByPosition.get(position);

            if (providerError != null) {
                // Proveedor caído: nunca inventamos un valor (FR-007).
                errorsByPosition.put(position,
                    QuoteException.unavailable(providerError.technicalDetail).atRequest(position, rawId));
                continue;
            }

            ExchangeRateClient.RateTable table = tablesByBase.get(originalCurrency);
            if (!table.isSupported) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.UNSUPPORTED_CURRENCY,
                    requestPrefix(position, rawId) + 'la moneda original ' + originalCurrency
                        + ' no es publicada por el proveedor de tipo de cambio.',
                    position, rawId));
                continue;
            }

            // Misma moneda: el tipo de cambio es 1. Si no, lo buscamos en la tabla del proveedor.
            Decimal rate = targetCurrency == originalCurrency ? 1 : table.rates.get(targetCurrency);
            if (rate == null) {
                errorsByPosition.put(position, QuoteException.validation(
                    QuoteException.UNSUPPORTED_CURRENCY,
                    requestPrefix(position, rawId) + 'la moneda destino ' + targetCurrency
                        + ' no es publicada por el proveedor de tipo de cambio.',
                    position, rawId));
                continue;
            }

            QuoteModels.QuoteResult result = new QuoteModels.QuoteResult();
            result.opportunityId = rawId.trim();
            result.originalAmount = opportunity.Amount;
            result.originalCurrency = originalCurrency;
            result.targetCurrency = targetCurrency;
            result.exchangeRate = rate;
            // Truncar a 2 decimales (FR-012): RoundingMode.DOWN corta hacia cero, sin redondear.
            result.convertedAmount = (opportunity.Amount * rate).setScale(2, System.RoundingMode.DOWN);
            result.quotedAt = table.fetchedAt;
            result.rateDate = table.rateDate;
            resultByPosition.put(position, result);
        }
        return resultByPosition;
    }

    /**
     * Etapa 6: guarda una cotización histórica por resultado, con UN solo insert (regla 6).
     * USER_MODE: el usuario necesita permiso de creación (permission set OpportunityQuoteUser).
     * Si el insert falla, el catch de quote() lo convierte en INTERNAL_ERROR.
     */
    private static void saveQuotes(
        List<QuoteModels.QuoteResult> results,
        Map<Integer, Opportunity> opportunityByPosition,
        String channel
    ) {
        List<CurrencyQuote__c> quotes = new List<CurrencyQuote__c>();
        for (Integer position = 1; position <= results.size(); position++) {
            QuoteModels.QuoteResult result = results[position - 1];
            quotes.add(new CurrencyQuote__c(
                Opportunity__c = opportunityByPosition.get(position).Id,
                OriginalAmount__c = result.originalAmount,
                OriginalCurrency__c = result.originalCurrency,
                TargetCurrency__c = result.targetCurrency,
                ExchangeRate__c = result.exchangeRate,
                ConvertedAmount__c = result.convertedAmount,
                QuotedAt__c = result.quotedAt,
                RateDate__c = result.rateDate,
                Channel__c = channel
            ));
        }
        Database.insert(quotes, AccessLevel.USER_MODE);
    }

    // ---------------------------------------------------------------------------------------------
    // Ayudantes
    // ---------------------------------------------------------------------------------------------

    /**
     * Convierte el texto recibido en un Id de Oportunidad. Devuelve null si está vacío, si no tiene
     * formato de Id o si es un Id de otro objeto (por ejemplo, de una Cuenta).
     */
    private static Id toOpportunityId(String rawId) {
        if (String.isBlank(rawId)) {
            return null;
        }
        try {
            Id candidate = Id.valueOf(rawId.trim());
            return candidate.getSObjectType() == Opportunity.SObjectType ? candidate : null;
        } catch (StringException e) {
            return null; // No tiene formato de Id de Salesforce
        }
    }

    /** Indica si el texto es un Id de Salesforce válido (de cualquier objeto). */
    private static Boolean isSalesforceId(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        try {
            Id.valueOf(value.trim());
            return true;
        } catch (StringException e) {
            return false;
        }
    }

    /** Comienzo común de los mensajes de error: "Pedido 2 (Id 006...): ". */
    private static String requestPrefix(Integer position, String rawId) {
        return 'Pedido ' + position + ' (Id ' + (String.isBlank(rawId) ? 'vacío' : rawId) + '): ';
    }

    /** Devuelve la menor posición de un conjunto (el primer pedido que falló). */
    private static Integer lowestPosition(Set<Integer> positions) {
        Integer lowest;
        for (Integer position : positions) {
            if (lowest == null || position < lowest) {
                lowest = position;
            }
        }
        return lowest;
    }
}
