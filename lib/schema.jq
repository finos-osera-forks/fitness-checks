# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Checks a value against a JSON Schema, for the keywords the standards repository's recipient guidance schema uses
# (docs/schemas/osera-recipient-guidance-0.1.0.schema.json): const, type, required, properties, items, minItems.
# Any other keyword is listed first as "unhandled keyword: <name>", so the caller never calls the value valid against a
# rule it did not check. Input: the value. Arguments: $schema (the schema, JSON), $name (the name of the value in the
# messages); $schema is read with --slurpfile, so it is an array of one. Output: the unhandled keywords, then one line
# per problem; nothing when the value is valid and every keyword is handled.

def problems($s; $path):
  # 1. a fixed value
  (
    if ($s | has("const")) and (. != $s.const) then
      "\($path) is \(tojson), the schema requires \($s.const | tojson)"
    else
      empty
    end
  ),
  # 2. the type, then what the type holds
  (
    if ($s | has("type")) and (type != $s.type) then
      "\($path) is of type \(type), the schema requires type \($s.type)"
    elif type == "object" then
      # 3. an object: the required keys, then each property the schema describes
      (
        ($s.required // [])[] as $k
        | if has($k) then empty else "\($path).\($k) is missing" end
      ),
      (
        (($s.properties // {}) | to_entries[]) as $p
        | if has($p.key) then (.[$p.key] | problems($p.value; "\($path).\($p.key)")) else empty end
      )
    elif type == "array" then
      # 4. an array: the minimum number of items, then each item
      (
        if ($s | has("minItems")) and (length < $s.minItems) then
          "\($path) has \(length) item(s), the schema requires at least \($s.minItems)"
        else
          empty
        end
      ),
      (
        if ($s | has("items")) then
          (to_entries[] | .key as $i | .value | problems($s.items; "\($path)[\($i)]"))
        else
          empty
        end
      )
    else
      empty
    end
  );

# The keywords this file checks, and the ones that describe without constraining. Any other keyword is listed, so a
# newer schema with a rule this file cannot check never passes in silence.
def handled:
  ["const", "type", "required", "properties", "items", "minItems",
   "$schema", "$id", "$comment", "title", "description", "examples", "default", "schema-version"];

# Every keyword this file does not handle: in the schema itself, in each property's schema, in the items' schema.
def unhandled($s):
  (
    $s | keys[] | select(. as $k | handled | index($k) | not)
  ),
  (
    (($s.properties // {}) | .[]) as $p
    | unhandled($p)
  ),
  (
    if ($s.items | type) == "object" then
      unhandled($s.items)
    else
      empty
    end
  );

# 1. the keywords this file cannot check, one line each, prefixed so the caller tells them from the problems
(
  [unhandled($schema[0])] | unique | .[] | "unhandled keyword: \(.)"
),
# 2. the problems of the value against the keywords it can check
problems($schema[0]; $name)
