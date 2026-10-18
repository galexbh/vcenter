# {{TITLE}}

| | |
|---|---|
| Entorno | {{ENV}} |
| Alcance | {{SCOPE}} |
| Fecha de la evaluación | {{DATE}} |
| Preparado por | {{PREPARED_BY}} |
| Identificador | {{AUDIT_ID}} |
| Versión | {{VERSION}} |
| Clasificación | **{{CLASSIFICATION}}** |

> Documento generado a partir de consultas de solo lectura a vCenter. Contiene información de infraestructura interna. Distribución restringida al personal autorizado.

## 1. Resumen ejecutivo

{{EXEC_SUMMARY}}

### Indicador por dominio

{{DOMAIN_SCORES}}

_Indicador interno de priorización: 100 − (15 × críticos + 5 × advertencias + 1 × informativos), mínimo 0. No constituye una certificación._

### Métricas clave

{{KEY_METRICS}}

### Evolución

{{EVOLUTION}}

## 2. Alcance y limitaciones

- Consultas de solo lectura vía govc; no se ejecutaron cambios.
- No se evalúan sistemas operativos invitados, aplicaciones, respaldos ni red física fuera del host.
- Las referencias a guías de seguridad son temáticas y orientativas.
- Las métricas de rendimiento cubren la ventana indicada en el resumen; lo que el nivel de estadísticas de vCenter no conserva se declara como cobertura.
- {{THRESHOLDS}}

**Cobertura**

{{COVERAGE}}

## 3. Hallazgos detallados

{{FINDINGS}}

## 4. Plan de remediación

Atender primero los críticos. Las acciones que modifiquen la plataforma requieren un cambio aprobado.

{{REMEDIATION}}

## 5. Revisión y aprobación

Las firmas no implican conformidad ni cierre de los hallazgos. Cualquier conclusión de cumplimiento normativo corresponde a Auditoría Interna, Riesgo Tecnológico y Seguridad de la Información.

| Rol | Nombre | Firma y fecha |
|---|---|---|
| Elaborado por | {{PREPARED_BY}} | |
| Revisado por (Arquitectura) | | |
| Revisado por (Seguridad de la Información) | | |
| Aprobado por (Responsable del servicio) | | |

---
_{{CLASSIFICATION}} · {{AUDIT_ID}} · Generado con scripts/Invoke-Audit.ps1_
