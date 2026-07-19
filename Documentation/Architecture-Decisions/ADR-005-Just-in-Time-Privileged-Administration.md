# ADR-005 – Just-in-Time Privileged Administration

## Status

Accepted

## Decision

Privileged administrative access was implemented using Microsoft Entra Privileged Identity Management with eligible role assignments and Just-in-Time activation.

## Design Rationale

- Permanent privileged access increases organizational risk.
- Administrative permissions should exist only when operationally required.
- Temporary privilege supports least privilege while maintaining administrative flexibility.
- Time-bound activation improves accountability, visibility, and auditability.

## Architectural Impact

The platform separates administrative role ownership from privilege activation, reducing standing administrative access while maintaining operational effectiveness.

## Implementation

This decision is implemented through Microsoft Entra Privileged Identity Management for both directory administration and Azure resource administration.
