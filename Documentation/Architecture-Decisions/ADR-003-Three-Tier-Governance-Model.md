# ADR-003 – Three-Tier Governance Model

## Status

Accepted

## Decision

Access governance was separated into three governance catalogs representing standard department access, business resource access, and privileged access.

## Design Rationale

- Different types of access require different governance controls.
- Separating governance responsibilities improves ownership and administrative clarity.
- Independent governance policies allow approval, review, and lifecycle settings to reflect business risk.
- The structure remains scalable as additional business resources are introduced.

## Architectural Impact

Governance policies become aligned with access sensitivity instead of treating every access request identically, resulting in clearer ownership and more consistent administration.

## Implementation

This decision is implemented through three Governance Catalogs containing department, business resource, and privileged access packages.
