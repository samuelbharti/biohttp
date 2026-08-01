---
name: Bug report
about: Something behaves differently from what the documentation says
title: ''
labels: bug
assignees: ''
---

## What happened

## What you expected instead

## Reproducible example

A self-contained example helps more than anything else. Please keep it offline:
use `httr2::with_mocked_responses()` rather than a real host, so the report does
not depend on a service being up.

```r
# your example here
```

## Which outcome did you get

If a call returned an envelope, paste `str(res)` with any credential removed.
`res$status` and `res$detail` are usually the two that matter.

```r

```

## Session info

```r
# sessioninfo::session_info() or utils::sessionInfo()
```
