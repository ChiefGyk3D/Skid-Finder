# Security policy

Skid Finder is a defensive tool that handles other people's radio metadata,
so two kinds of report matter: a defect in the tool itself, and a way the
tool could be turned against the people it is meant to protect.

## Reporting

Email <chief@chiefgyk3d.com> with "Skid Finder security" in the subject, or
open a [private security advisory](https://github.com/ChiefGyk3D/Skid-Finder/security/advisories/new)
on GitHub. Please do not open a public issue for anything that could be
exploited before it is fixed. You will get an acknowledgement within a
week, and a fix or a decision within thirty days for anything confirmed.

Include what you did, what you expected, what happened, and the output of
`./scripts/skid-finder.sh --doctor` if it is relevant. A capture that
demonstrates the problem is welcome as a `.btsnoop` or `.pcapng`; scrub or
withhold it if it contains addresses you would not want published.

## What counts

- A way to make the toolkit **transmit**, associate, deauthenticate or
  otherwise interfere. It is receive-only by design; anything else is a
  bug of the highest priority.
- Code execution or privilege escalation through a config file, a capture,
  a record from another sensor, or a broker message. Config is parsed as
  data, records are parsed as JSON, and nothing is `source`d or `eval`ed
  from input; a way around that is a report.
- The collector or publisher leaking credentials, or accepting them from a
  place they should not come from (they are environment-only).
- A detector that can be made to stay silent on a real flood, or to fire on
  ordinary traffic in a way the corpus gate does not catch. Send the
  capture; it becomes a corpus sample.
- Records that identify a person more precisely than the identity tier
  claims.

## What does not

- The thresholds being wrong for your venue. They are tunable and the
  README says how to baseline them; that is an issue, not an advisory.
- Behaviour on hardware the roadmap marks unverified.

## Supported versions

Pre-1.0, only the latest tagged pre-release and `main` receive fixes.
