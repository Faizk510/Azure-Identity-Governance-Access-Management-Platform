# ADR-001 – Governance-First Identity Architecture

## Status

Accepted

## Decision

The platform was designed using a Governance-First identity model, where department access is provisioned and managed through Microsoft Entra Identity Governance rather than automatically through attribute-based group membership.

## Design Rationale

- Identity Governance was the primary capability the project set out to demonstrate.
- Access approval, periodic reviews, and lifecycle governance were treated as core platform capabilities rather than secondary controls.
- Governance-first provisioning provides a consistent approval and audit process before access is granted.
- The design aligns with least privilege and controlled access principles while maintaining clear business ownership.

## Architectural Impact

Access management becomes part of the governance process rather than an automatic directory operation. This allows approvals, lifecycle automation, and access reviews to operate as a single governance model throughout the platform.

## Implementation

This decision is reflected throughout the Identity Governance implementation, including Governance Catalogs, Access Packages, Lifecycle Workflows, and Access Reviews.
