# ADR-004 – Risk-Based Access Review Strategy

## Status

Accepted

## Decision

Access Reviews were designed using governance policies appropriate to the sensitivity and purpose of the access being reviewed.

## Design Rationale

- Different access types present different operational and security risks.
- Review ownership should align with those responsible for the resource.
- Governance frequency should reflect business risk rather than administrative convenience.
- A consistent review framework supports ongoing access validation without unnecessary operational overhead.

## Architectural Impact

The platform applies governance controls proportionate to access sensitivity, allowing department access, business resources, and privileged access to follow independent review models while remaining part of a unified governance framework.

## Implementation

This decision is reflected throughout the Access Review configuration across all Governance Catalogs.
