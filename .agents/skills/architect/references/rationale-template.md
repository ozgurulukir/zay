# Rationale template

The prose that ships alongside the type sketch. Keep it to one page, sentence-case headings, replacing italic prompts with concrete content.

## Problem

_One paragraph: what we are building, and which constraints surfaced during [Ground](../SKILL.md#ground) make the shape non-obvious (existing types to interop with, callers we cannot break, boundary invariants)._

## Usage (caller's view)

_Write this first, before the type sketch. Show two or three realistic call sites in caller code: what they import, what they call, and what comes back. Derive the type sketch in [Shape](#shape) from this usage; reconcile types to usage if they diverge._

## Shape

_The chosen architecture: data structures first, then data flow through signatures. Name load-bearing decisions—which invariants are encoded in types, where validation lives, and what the design deliberately omits—and name the invariant or pattern behind each choice._

## Tradeoffs accepted

_One bullet per tradeoff ("We accept X in exchange for Y"). Call out anything a future reader might mistake for an oversight._

## Alternatives considered

_Name at least one concrete alternative shape and why it lost (e.g., wrong owner, cross-layer dependency, extra mutable state). Use two or three when real contenders existed; if constraints forced a single viable shape, state why._

## Open questions and risks

_Decisions needing user input or risks worth flagging before implementation. Phrase each open point as a concrete question._

## Next implementation step

_One sentence naming the first concrete file/test to write against the sketch._
