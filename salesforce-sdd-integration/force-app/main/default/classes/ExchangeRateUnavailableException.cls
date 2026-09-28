/**
 * ExchangeRateUnavailableException
 *
 * Qué hace: representa que el proveedor de tipo de cambio (currency-api) no respondió, tardó demasiado
 * o respondió con un error (HTTP 500, código EXCHANGE_RATE_UNAVAILABLE).
 *
 * Por qué existe: en ese caso no hay que inventar ni estimar ningún valor (FR-007); el llamador
 * debe reintentar más tarde.
 *
 * Se crea con QuoteException.unavailable(...), que completa el código, el mensaje y el HTTP 500.
 */
public with sharing class ExchangeRateUnavailableException extends QuoteException {
}
