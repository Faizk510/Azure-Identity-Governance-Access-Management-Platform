# ADR-002 – Native Lifecycle Workflows

## Status

Accepted

## Decision

Joiner, Mover, and Leaver processes were implemented using native Microsoft Entra Lifecycle Workflows.

## Design Rationale

- Native capabilities satisfied the automation requirements without introducing unnecessary infrastructure.
- Reducing external components simplified deployment, administration, and ongoing maintenance.
- Native workflows integrate directly with Microsoft Entra Identity Governance.
- The solution remains easier to understand, support, and extend.

## Architectural Impact

Identity lifecycle automation remains fully integrated within the Microsoft Entra platform, reducing operational complexity while maintaining governed provisioning and deprovisioning.

## Implementation

This decision is implemented through department-based Joiner, Mover, and Leaver workflows using Microsoft Entra Lifecycle Workflows.
