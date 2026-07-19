# ADR-006 – Security Framework Alignment

## Status

Accepted

## Decision

The platform architecture was designed using principles aligned with NIST Cybersecurity Framework (CSF) 2.0 and NIST SP 800-63, together with Microsoft Entra recommendations and established Identity and Access Management (IAM) practices.

## Design Rationale

- A recognized security framework provides consistency for architectural decisions.
- Risk-based governance supports least privilege, identity lifecycle management, and privileged access control.
- Microsoft platform guidance ensures the implementation aligns with recommended capabilities and operational patterns.
- Security decisions remain driven by business requirements rather than technology alone.

## Architectural Impact

Security principles become foundational architectural considerations rather than isolated technical controls, creating a consistent governance model across the platform.

## Implementation

This alignment is reflected throughout Identity Administration, Identity Governance, Lifecycle Management, Privileged Identity Management, Conditional Access, and the IAM Operations Toolkit.
