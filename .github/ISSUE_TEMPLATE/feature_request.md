---
name: Feature request
about: Suggest something biohttp should do
title: ''
labels: enhancement
assignees: ''
---

## What you are trying to do

Describe the problem rather than the solution, if you can. It often turns out
there is already a way, or that a smaller change solves it.

## Does it fit the scope

biohttp is the transport layer and nothing else. These are out of scope by
design, and `CONTRIBUTING.md` explains why:

- Anything that knows what a gene is. Service-specific knowledge belongs in a
  client package built on top.
- Parsing beyond JSON and text bodies.
- Vendor-specific retry or rate-limit numbers. The package supplies the
  mechanism, the client supplies the policy.
- A worker pool for fanning out across many different services at once.

If your request is one of those, say how you would keep it inside the line.

## New dependencies

A new entry in `Imports` is inherited by everything downstream, so it is a
discussion before it is a pull request. If your idea needs one, name it here.
