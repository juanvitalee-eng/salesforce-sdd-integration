Este es un proyecto de aprendizaje personal de Spec Driven Development en Salesforce,
construido por un consultor/admin de Salesforce que está aprendiendo a programar, con el
objetivo de prepararse para un rol de Forward Deployed Engineer.

El proyecto expone una integración REST de entrada (Apex REST) que cotiza Oportunidades
en otra moneda usando una API externa de tipo de cambio, y esa misma lógica se reutiliza
como una Agentforce Action para consultas en lenguaje natural.

Convenciones de nomenclatura:
1) Todo API Name de metadata (objetos, campos, clases) se escribe en inglés, en
   PascalCase o camelCase según corresponda. El Label siempre va en español.
2) Todo objeto y campo debe tener una descripción en español, sin excepción.
3) Todo trigger debe delegar toda su lógica a una clase Handler; nunca lógica de
   negocio escrita directamente en el trigger.

Arquitectura de código:
4) Separar siempre en tres capas: una clase REST Resource (solo maneja HTTP), una
   clase Service (lógica de negocio), y una clase de integración dedicada exclusivamente
   a cada callout externo.
5) Todo callout HTTP debe ejecutarse ANTES de cualquier operación DML dentro de la misma
   transacción, nunca después.
6) Nunca ejecutar SOQL ni DML dentro de un loop; todo el código debe estar bulkificado
   (diseñado para procesar listas, no un solo registro a la vez), incluso si el caso de
   uso actual maneja de a uno.
7) Usar clases de Wrapper tipadas para el body de requests y responses REST, nunca
   Map<String, Object> sueltos.
8) Definir clases de Exception propias y específicas del dominio, nunca dejar
   propagarse excepciones genéricas de Salesforce sin capturar.
9) Toda clase Apex debe declarar explícitamente "with sharing".
10) Nunca hardcodear URLs, usuarios, contraseñas, API keys, ni valores de configuración:
    usar Named Credentials / External Credentials para endpoints externos, y Custom
    Metadata Types para configuración de negocio.
11) Cuando exista trabajo secundario que no sea indispensable para responder al llamador
    (por ejemplo, notificaciones), debe ejecutarse en un Queueable, nunca de forma
    síncrona dentro del mismo hilo del callout REST principal. Esta regla aplica a
    futuras funcionalidades, no obliga a crear casos de uso artificiales en la v1.

Calidad y pruebas:
12) Nunca sobrescribir datos originales de la Oportunidad: cada cotización se guarda como
    un registro nuevo en el objeto CurrencyQuote__c, para mantener trazabilidad.
13) Todo el código Apex debe tener clases de test con al menos 85% de cobertura, usando
    mocks (HttpCalloutMock) para simular las llamadas externas — nunca tests que dependan
    de la disponibilidad real de la API externa.
14) Cualquier acción expuesta a Agentforce debe reutilizar la lógica de negocio existente
    (la clase Service), nunca duplicar código solo para que un agente la consuma.
15) Todo el código debe tener comentarios claros explicando qué hace y por qué, pensado
    para alguien que no es programador de formación.
16) Priorizar código simple y legible por sobre código "elegante" u optimizado en exceso.