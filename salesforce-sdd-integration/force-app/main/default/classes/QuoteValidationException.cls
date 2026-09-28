/**
 * QuoteValidationException
 *
 * Qué hace: representa un error en el PEDIDO del llamador (HTTP 400). Por ejemplo: el Id de
 * Oportunidad no existe, la moneda no es válida o la lista está vacía.
 *
 * Por qué existe: separar "el pedido está mal" (400) de "el servicio falló" (500) permite que el
 * sistema externo sepa si tiene que corregir su pedido o reintentar más tarde.
 *
 * Se crea con QuoteException.validation(...), que completa el código y el HTTP 400.
 */
public with sharing class QuoteValidationException extends QuoteException {
}
