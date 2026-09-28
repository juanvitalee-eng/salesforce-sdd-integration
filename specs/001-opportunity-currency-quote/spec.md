# Feature Specification: Cotizador de Oportunidades

**Feature Branch**: `001-opportunity-currency-quote`

**Created**: 2026-09-27

**Status**: Draft

**Input**: User description: "Cotizador de Oportunidades: un sistema externo (ERP/CRM) necesita conocer el monto de una Oportunidad de Salesforce convertido a otra moneda, usando el tipo de cambio del día. Además, un usuario interno debe poder pedir lo mismo conversando con un agente de Agentforce en lenguaje natural. Cada cotización queda guardada como registro histórico (CurrencyQuote__c) sin modificar la Oportunidad."

## Clarifications

### Session 2026-09-28

- Q: ¿La org tiene Multi-Currency habilitado o todas las Oportunidades usan la moneda corporativa? → A: Multi-Currency está habilitado en la org; la moneda original de cada Oportunidad es su propio campo de moneda (`CurrencyIsoCode`).
- Q: ¿Qué proveedor externo de tipo de cambio se usa? → A: currency-api (proyecto open source "fawazahmed0/exchange-api", servido por jsDelivr): sin API key, 200+ monedas incluyendo ARS, actualización diaria. *(Reemplaza la decisión inicial de usar Frankfurter, descartada porque no publica ARS.)*
- Q: ¿Se deja algún registro técnico cuando una cotización falla? → A: Sí, en un objeto de log de errores genérico y reutilizable por otras funcionalidades (`ErrorLog__c`), no uno específico de cotizaciones.
- Q: ¿Cómo se redondea el monto convertido a 2 decimales? → A: Truncando: se descartan los decimales sobrantes sin redondear (1.234,569 → 1.234,56).
- Q: ¿Qué pasa con las cotizaciones históricas si se borra la Oportunidad? → A: No se puede borrar una Oportunidad que tenga cotizaciones (relación Lookup que impide el borrado); el historial queda siempre protegido.
- Q: ¿Quién decide qué monedas acepta el Cotizador? → A: Un administrador, con una lista configurable de monedas habilitadas (Custom Metadata), sin desplegar código. Una moneda (original o destino) solo se puede cotizar si está habilitada en la lista **y** el proveedor la publica.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cotización solicitada por un sistema externo (Priority: P1)

Un sistema externo (ERP/CRM) envía a Salesforce uno o más pedidos de cotización, cada uno con el Id de una Oportunidad y una moneda destino. Por cada pedido recibe el monto original, la moneda original, la moneda destino, el monto convertido, el tipo de cambio aplicado y la fecha/hora de la cotización. Si algo falla, recibe un mensaje de error claro y un código de estado que le permite saber si el problema está en su pedido (400) o en el servicio (500).

**Why this priority**: Es la necesidad de negocio principal y el núcleo sobre el que se apoyan las otras dos historias: sin la cotización no hay nada que registrar ni que exponer al agente.

**Independent Test**: Se puede probar por completo enviando un pedido con un Id de Oportunidad válido y una moneda soportada, y verificando que la respuesta contiene los seis datos esperados y que los valores son coherentes (monto convertido = monto original × tipo de cambio).

**Acceptance Scenarios**:

1. **Given** una Oportunidad existente con monto 10.000 USD, **When** el sistema externo pide la cotización en EUR, **Then** recibe monto original 10.000, moneda original USD, moneda destino EUR, el tipo de cambio del día, el monto convertido y la fecha/hora de la cotización, con código 200.
2. **Given** un Id que no corresponde a ninguna Oportunidad (o que no tiene un formato de Id válido), **When** el sistema externo pide la cotización, **Then** recibe un mensaje de error claro en lenguaje de negocio (por ejemplo, "La Oportunidad indicada no existe") y código 400, sin mensajes técnicos internos.
3. **Given** una Oportunidad existente, **When** el sistema externo pide una moneda destino que el proveedor de tipo de cambio no soporta, **Then** recibe un mensaje de error claro indicando que la moneda no está soportada y código 400.
4. **Given** que el proveedor de tipo de cambio no responde o responde con error, **When** el sistema externo pide una cotización, **Then** recibe un mensaje de error claro indicando que el tipo de cambio no está disponible, código 500, ningún dato inventado, y no se crea ningún registro histórico.
5. **Given** una lista con varios pedidos válidos, **When** el sistema externo la envía en una sola llamada, **Then** recibe un resultado por cada pedido, en el mismo orden en que los envió.
6. **Given** una lista de 3 pedidos donde el segundo tiene un Id inexistente, **When** el sistema externo la envía, **Then** recibe código 400 con un mensaje claro que identifica el pedido 2 como el que falló, ninguna cotización y ningún registro histórico creado (ni siquiera para los pedidos 1 y 3).
7. **Given** una Oportunidad cuya moneda original no está habilitada en la lista de monedas del Cotizador, **When** el sistema externo pide la cotización, **Then** recibe un mensaje claro indicando que la moneda no está habilitada y código 400, sin registro histórico.
8. **Given** una Oportunidad en ARS (moneda habilitada), **When** el sistema externo pide la cotización en USD, **Then** recibe la cotización con el tipo de cambio del día del proveedor y código 200.

---

### User Story 2 - Cotización conversando con el agente de Agentforce (Priority: P2)

Un usuario interno de Salesforce le escribe al agente de Agentforce algo como "cotizame la oportunidad 006XXXXXXXXXXXX en EUR". El agente responde en lenguaje natural con la misma información que recibe el sistema externo: monto original y su moneda, moneda destino, monto convertido, tipo de cambio aplicado y fecha/hora de la cotización. Las reglas y los resultados son exactamente los mismos que en la Historia 1, porque ambos canales usan la misma lógica de cotización.

**Why this priority**: Aporta valor a usuarios internos, pero depende de que la lógica de la Historia 1 exista; es un segundo canal de acceso a la misma capacidad.

**Independent Test**: Con la Historia 1 implementada, se prueba pidiéndole al agente una cotización para una Oportunidad conocida y comparando su respuesta con la del canal externo para el mismo Id y moneda en el mismo momento: los valores deben coincidir.

**Acceptance Scenarios**:

1. **Given** una Oportunidad existente y visible para el usuario, **When** el usuario pide al agente "cotizame la oportunidad <Id> en EUR", **Then** el agente responde con los seis datos de la cotización en lenguaje natural.
2. **Given** un Id inexistente o inválido, **When** el usuario pide la cotización al agente, **Then** el agente explica claramente que la Oportunidad no existe o que el Id no es válido, sin mostrar errores técnicos.
3. **Given** una moneda no soportada o el proveedor de tipo de cambio caído, **When** el usuario pide la cotización al agente, **Then** el agente comunica el mismo motivo de error que recibiría el sistema externo y no inventa ningún valor.
4. **Given** que el usuario no indica el Id o la moneda destino, **When** le habla al agente, **Then** el agente le pide el dato que falta antes de intentar cotizar.

---

### User Story 3 - Registro histórico de cotizaciones para auditoría (Priority: P3)

El responsable de auditoría puede consultar en Salesforce un registro histórico por cada cotización exitosa, sin importar si se pidió desde el sistema externo o desde el agente. La Oportunidad nunca se modifica: su monto y moneda originales quedan intactos.

**Why this priority**: Es un requisito de trazabilidad importante, pero no bloquea la entrega de la cotización al llamador.

**Independent Test**: Se pide una cotización exitosa y se verifica que existe un nuevo registro histórico con todos los datos de la cotización vinculado a la Oportunidad, y que el monto y la moneda de la Oportunidad no cambiaron.

**Acceptance Scenarios**:

1. **Given** una cotización exitosa, **When** el auditor revisa la Oportunidad, **Then** encuentra un nuevo registro histórico vinculado con monto original, moneda original, moneda destino, tipo de cambio, monto convertido, fecha/hora y canal de origen (sistema externo o agente).
2. **Given** una cotización exitosa, **When** se compara la Oportunidad antes y después, **Then** su monto y su moneda no cambiaron.
3. **Given** una cotización que falló por cualquier motivo (Id inválido, moneda no soportada, proveedor caído), **When** el auditor revisa los registros históricos, **Then** no existe ningún registro nuevo para ese pedido.
4. **Given** tres cotizaciones de la misma Oportunidad a lo largo del día, **When** el auditor las revisa, **Then** ve tres registros independientes; ninguno reemplaza a otro.

---

### Edge Cases

- **Oportunidad sin monto** (monto vacío): se responde con un error claro de pedido inválido (400) indicando que la Oportunidad no tiene monto para cotizar, y no se crea registro histórico.
- **Moneda destino igual a la moneda original**: se permite; el tipo de cambio es 1 y el monto convertido es igual al original. Se registra igual que cualquier otra cotización.
- **Moneda destino vacía o con formato incorrecto** (por ejemplo, "euro" en vez de "EUR"): error claro de pedido inválido (400).
- **Código que el proveedor publica pero no está habilitado** (por ejemplo, una criptomoneda como "BTC"): error de pedido inválido (400) indicando que la moneda no está habilitada.
- **Moneda destino en minúsculas** ("eur"): se interpreta sin distinguir mayúsculas de minúsculas.
- **Lista vacía o cuerpo del pedido mal formado**: error claro de pedido inválido (400).
- **Lista que supera el máximo permitido de pedidos por llamada**: error claro de pedido inválido (400) indicando el máximo.
- **Mismo Id de Oportunidad repetido en la lista** (con igual o distinta moneda): cada pedido se trata como independiente y genera su propio resultado y registro.
- **Oportunidad que existe pero el usuario del agente no tiene permiso para ver**: se trata igual que una Oportunidad inexistente, sin revelar que existe.
- **Intento de borrar una Oportunidad con cotizaciones**: la plataforma lo impide con un mensaje claro; la Oportunidad y su historial quedan intactos.
- **Lista con pedidos válidos e inválidos mezclados**: se aplica "todo o nada". Si falla cualquier pedido, se rechaza la lista completa con el código del primer error encontrado (en el orden de los pedidos), no se devuelve ninguna cotización y no se crea ningún registro histórico.

## Requirements *(mandatory)*

### Functional Requirements

**Canal externo**

- **FR-001**: El sistema DEBE ofrecer un punto de acceso de integración para sistemas externos que reciba una lista de uno o más pedidos de cotización, cada uno con un Id de Oportunidad y un código de moneda destino.
- **FR-002**: Por cada pedido exitoso, el sistema DEBE devolver: monto original, moneda original, moneda destino, monto convertido, tipo de cambio aplicado y fecha/hora de la cotización.
- **FR-003**: El sistema DEBE devolver los resultados en el mismo orden en que se recibieron los pedidos, de modo que el llamador pueda asociar cada resultado con su pedido.
- **FR-004**: El sistema DEBE aceptar hasta 200 pedidos por llamada y rechazar con error de pedido inválido las listas vacías o que superen ese máximo.

**Validaciones y errores**

- **FR-005**: Si el Id de Oportunidad no existe, no tiene un formato válido o la Oportunidad no es visible para quien consulta, el sistema DEBE responder con un mensaje claro en lenguaje de negocio y código de pedido inválido (HTTP 400).
- **FR-006**: Si la moneda destino o la moneda original de la Oportunidad no está habilitada en la lista de monedas del Cotizador (FR-025), o no es publicada por el proveedor de tipo de cambio, el sistema DEBE responder con un mensaje claro que indique cuál de los dos motivos aplica y código de pedido inválido (HTTP 400).
- **FR-007**: Si el proveedor de tipo de cambio no responde, tarda más del tiempo máximo permitido o responde con error, el sistema DEBE responder con un mensaje claro y código de error del servicio (HTTP 500), sin devolver ningún valor estimado, guardado o inventado.
- **FR-008**: Los mensajes de error NUNCA DEBEN exponer detalles técnicos internos (trazas, nombres internos, mensajes crudos de la plataforma).
- **FR-009**: Si la Oportunidad no tiene monto, el sistema DEBE responder con un error claro de pedido inválido (HTTP 400).
- **FR-010**: El procesamiento de una lista DEBE ser "todo o nada": si cualquier pedido falla, el sistema DEBE rechazar la lista completa con el código del primer error encontrado (en el orden de los pedidos), con un mensaje claro que indique qué pedido falló (su posición e Id) y por qué. En ese caso no se devuelve ninguna cotización y no se crea ningún registro histórico, ni siquiera para los pedidos que eran válidos.

**Cálculo**

- **FR-011**: El monto convertido DEBE calcularse como monto original × tipo de cambio vigente informado por el proveedor al momento del pedido.
- **FR-012**: El monto convertido DEBE truncarse a 2 decimales (se descartan los decimales sobrantes, sin redondear: 1.234,569 → 1.234,56; en montos negativos se trunca hacia cero); el tipo de cambio DEBE conservarse con la precisión informada por el proveedor (al menos 10 decimales, porque monedas de bajo valor como ARS tienen tasas del orden de 0,0006).
- **FR-013**: La fecha/hora de la cotización DEBE ser el momento en que el sistema obtuvo el tipo de cambio, expresada en formato estándar con zona horaria (UTC).

**Canal conversacional (agente)**

- **FR-014**: Un usuario interno DEBE poder pedir una cotización al agente de Agentforce en lenguaje natural indicando el Id de la Oportunidad y la moneda destino.
- **FR-015**: El agente DEBE devolver la misma información y aplicar exactamente las mismas reglas de validación, cálculo y registro que el canal externo; la lógica de cotización DEBE ser única y compartida por ambos canales, sin duplicación.
- **FR-016**: Si falta el Id o la moneda destino en el pedido del usuario, el agente DEBE solicitar el dato faltante antes de cotizar.

**Registro histórico**

- **FR-017**: Por cada cotización exitosa, el sistema DEBE crear un nuevo registro histórico de cotización vinculado a la Oportunidad, con monto original, moneda original, moneda destino, tipo de cambio, monto convertido, fecha/hora de la cotización y canal de origen.
- **FR-018**: El sistema NO DEBE crear ningún registro histórico para pedidos que fallen, cualquiera sea el motivo.
- **FR-019**: El sistema NUNCA DEBE modificar ningún dato de la Oportunidad cotizada.
- **FR-020**: Los registros históricos DEBEN ser de solo consulta para usuarios de negocio: no se editan ni reemplazan después de creados.
- **FR-020a**: El sistema DEBE impedir el borrado de una Oportunidad que tenga al menos una cotización histórica, para que el historial nunca se pierda.

**Registro de errores**

- **FR-021**: Por cada llamada rechazada (canal externo o agente), el sistema DEBE crear un registro en un log de errores genérico (`ErrorLog__c`) con: fecha/hora, funcionalidad de origen (por ejemplo, "Cotizador de Oportunidades"), canal (sistema externo o agente), tipo de error (pedido inválido 400 o error del servicio 500), el mensaje de negocio devuelto al llamador, el detalle técnico interno y la referencia al pedido que falló (posición e Id de Oportunidad, si existe).
- **FR-022**: El registro de error DEBE guardarse aunque la lista completa sea rechazada ("todo o nada" aplica solo a las cotizaciones históricas, no al log de errores).
- **FR-023**: El log de errores DEBE ser genérico: su estructura no puede depender del Cotizador, para que otras funcionalidades futuras lo reutilicen.
- **FR-024**: El detalle técnico del log es solo para administradores; nunca se expone al llamador (FR-008). Los usuarios de negocio no tienen acceso al log de errores.

**Monedas habilitadas**

- **FR-025**: El sistema DEBE permitir que un administrador defina qué monedas acepta el Cotizador mediante una lista configurable (alta, baja o desactivación de una moneda) sin desplegar código. La lista aplica tanto a la moneda original de la Oportunidad como a la moneda destino.
- **FR-026**: La validación contra la lista de monedas habilitadas DEBE hacerse antes de consultar al proveedor, para no gastar consultas en pedidos que igual se van a rechazar.

### Key Entities

- **Oportunidad**: registro de negocio existente en Salesforce. Aporta el monto original y la moneda original; la moneda original es la moneda propia de cada Oportunidad (`CurrencyIsoCode`, la org tiene Multi-Currency habilitado), no la moneda corporativa. Es solo de lectura para esta funcionalidad.
- **Pedido de cotización**: lo que envía el llamador. Contiene el Id de la Oportunidad y el código de moneda destino (código de 3 letras, estándar ISO 4217).
- **Resultado de cotización**: lo que se devuelve por cada pedido. Si fue exitoso, incluye monto original, moneda original, moneda destino, monto convertido, tipo de cambio y fecha/hora. Si falló, incluye el motivo en lenguaje claro.
- **Cotización histórica (CurrencyQuote__c)**: registro permanente de cada cotización exitosa. Se vincula obligatoriamente a una Oportunidad (una Oportunidad puede tener muchas cotizaciones; la relación es de búsqueda y bloquea el borrado de la Oportunidad mientras tenga cotizaciones) e incluye los mismos datos del resultado exitoso más el canal de origen (sistema externo o agente).
- **Log de errores (ErrorLog__c)**: registro técnico genérico, reutilizable por cualquier funcionalidad, de cada llamada rechazada. Incluye fecha/hora, funcionalidad de origen, canal, tipo de error, mensaje de negocio, detalle técnico y referencia al registro/pedido involucrado. Solo visible para administradores. No está vinculado obligatoriamente a una Oportunidad.
- **Moneda habilitada**: código ISO 4217 de 3 letras que un administrador habilitó para el Cotizador, con un indicador de activa/inactiva.
- **Proveedor de tipo de cambio**: servicio externo único (currency-api) que informa el tipo de cambio vigente entre dos monedas y qué monedas publica.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: El 95% de los pedidos de una sola cotización reciben respuesta en menos de 3 segundos cuando el proveedor de tipo de cambio funciona con normalidad.
- **SC-002**: El 100% de las cotizaciones exitosas cumplen que el monto convertido es igual a monto original × tipo de cambio, truncado a 2 decimales.
- **SC-003**: El 100% de las cotizaciones exitosas tienen exactamente un registro histórico asociado, y el 0% de los pedidos fallidos (o de las listas rechazadas) genera alguno.
- **SC-004**: El 0% de las Oportunidades cotizadas cambian su monto o su moneda como consecuencia de una cotización.
- **SC-005**: El 100% de las respuestas de error contienen un mensaje comprensible para una persona de negocio y ninguna contiene detalles técnicos internos.
- **SC-006**: Para el mismo Id, moneda y tipo de cambio, el canal externo y el agente devuelven valores idénticos en el 100% de los casos.
- **SC-007**: Un usuario interno obtiene una cotización del agente en una sola interacción (un mensaje y una respuesta) cuando indica Id y moneda.
- **SC-008**: Una llamada con 200 pedidos válidos se procesa completa sin fallar por volumen.
- **SC-009**: El 100% de las llamadas rechazadas (400 o 500) generan exactamente un registro en el log de errores, y el 0% de las cotizaciones exitosas genera alguno.

## Assumptions

- El sistema externo ya está autorizado para integrarse con Salesforce mediante el mecanismo de autenticación estándar de la organización; definir ese mecanismo está fuera de alcance.
- "Tipo de cambio del día" significa el tipo de cambio vigente que informa el proveedor en el momento del pedido; no se guardan tipos de cambio en caché para reutilizarlos.
- La org tiene Multi-Currency habilitado: cada Oportunidad puede estar en una moneda distinta, y la cotización siempre parte de la moneda propia de la Oportunidad. Las tasas de conversión configuradas dentro de Salesforce NO se usan para cotizar; el tipo de cambio sale siempre del proveedor externo.
- El único proveedor de tipo de cambio es **currency-api** (proyecto open source `fawazahmed0/exchange-api`, servido por la CDN jsDelivr). No requiere API key, publica 200+ monedas (incluidas ARS y criptomonedas) y se actualiza una vez por día; "tipo de cambio del día" es el último publicado. No tiene SLA: se acepta ese riesgo para un proyecto de aprendizaje. Las criptomonedas y cualquier moneda no deseada quedan fuera mediante la lista de monedas habilitadas (FR-025).
- Como el proveedor puede informar en una sola consulta todas las tasas de una moneda base, un lote de hasta 200 pedidos no requiere una consulta por pedido.
- El máximo de 200 pedidos por llamada es un valor por defecto razonable; se puede ajustar por configuración.
- El tiempo máximo de espera al proveedor es de 10 segundos; si se supera, se considera que no respondió (FR-007).
- La visibilidad de Oportunidades respeta los permisos del usuario que consulta (el usuario de integración para el canal externo y el usuario interno para el agente).
- El agente recibe directamente el Id de la Oportunidad; no busca Oportunidades por nombre.
- **Fuera de alcance para v1**: búsqueda de Oportunidades por nombre desde el agente, soporte de más de un proveedor de tipo de cambio, y notificaciones o procesos en segundo plano.
