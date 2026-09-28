# Contrato: Agent Action "Cotizar Oportunidad" (canal agente)

Clase: `OpportunityQuoteAction`, método `@InvocableMethod(label='Cotizar Oportunidad en otra moneda')`.
Reutiliza `OpportunityQuoteService` con canal `Agent` (FR-015, regla 14).

## Entradas (`@InvocableVariable`, ambas `required = true`)

| Nombre | Label / descripción para el agente | Tipo |
|---|---|---|
| `opportunityId` | "Id de la Oportunidad (15 o 18 caracteres, empieza con 006)" | String |
| `targetCurrency` | "Código de 3 letras de la moneda destino, por ejemplo EUR" | String |

## Salidas

| Nombre | Tipo | Cuándo |
|---|---|---|
| `isSuccess` | Boolean | Siempre |
| `message` | String | Siempre. Si hubo éxito, un resumen en español; si hubo error, el mismo mensaje de negocio que el canal REST |
| `errorCode` | String | Solo si hubo error (catálogo de [data-model.md](../data-model.md#catálogo-de-códigos-de-error)) |
| `originalAmount`, `convertedAmount`, `exchangeRate` | Decimal | Solo si hubo éxito |
| `originalCurrency`, `targetCurrency` | String | Solo si hubo éxito |
| `quotedAt` | String (ISO 8601 UTC) | Solo si hubo éxito |

La acción **nunca** lanza excepciones hacia el agente: los errores vuelven como `isSuccess = false`.

## Implementación real (2026-09-28)

El agente se creó con el **nuevo Agentforce Builder (Agent Script)**, no con Topics/Actions clásicos:

- Fuente versionada: `force-app/main/default/aiAuthoringBundles/OpportunityCurrencyQuote/OpportunityCurrencyQuote.agent`
  (subagent `opportunity_quote` + acción `quote_opportunity` con `target: "apex://OpportunityQuoteAction"`).
- Flujo: editar el `.agent` → `sf agent validate authoring-bundle` → `sf agent publish authoring-bundle`
  → `sf agent activate`. El publish genera y trae al repo `bots/` y `genAiPlannerBundles/`.
- Es un agente de tipo **Service Agent**: corre como su propio usuario (`opportunitycurrencyquote@...ext`,
  perfil Einstein Agent User), que tiene asignado `OpportunityQuoteUser`. Por eso la visibilidad de
  Oportunidades es la de ese usuario, no la del usuario interno que conversa (ver "Desvío" abajo).
- Permiso extra descubierto: para usar la External Credential, el usuario necesita **Read sobre
  `UserExternalCredential`** (agregado a `OpportunityQuoteUser`).

**Desvío respecto de la spec**: el supuesto "la visibilidad respeta los permisos del usuario interno"
(FR-005 para el canal agente) no se cumple con un Service Agent. Para cumplirlo habría que usar un
agente de empleados (Employee Agent), que corre con el usuario que conversa.

## Configuración en Agentforce Builder (diseño original)

- **Agent Action**: tipo Apex → `OpportunityQuoteAction`. Marcar ambas entradas como "Require Input"
  y las salidas como "Show in conversation".
- **Topic**: "Cotización de Oportunidades"
  - Descripción: "Cotiza el monto de una Oportunidad de Salesforce en otra moneda con el tipo de
    cambio del día."
  - Instrucciones:
    1. "Si el usuario no indicó el Id de la Oportunidad o la moneda destino, pedíselo antes de
       ejecutar la acción."
    2. "Respondé con monto original y moneda, moneda destino, tipo de cambio, monto convertido y
       fecha/hora de la cotización."
    3. "Si la acción devuelve isSuccess = false, comunicá el mensaje recibido tal cual y nunca
       inventes ni estimes valores."
    4. "No busques Oportunidades por nombre; solo se aceptan Ids."
- Recuperar la metadata al repo:
  `sf project retrieve start --metadata GenAiFunction GenAiPlugin GenAiPlannerBundle --target-org sdd-dev`
