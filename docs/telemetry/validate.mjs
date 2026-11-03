#!/usr/bin/env node
// Validates the telemetry contract in this directory. No dependencies.
//
//   node docs/telemetry/validate.mjs
//
// Four checks, in order of how expensive the mistake is to undo:
//
//   1. Every example conforms to event-schema.json.
//   2. The endpoint transform emits only top-level keys that log2logstash
//      allows. Anything else is silently dropped by log2logstash, with no
//      error, so this can only be caught here or by noticing missing data
//      on a dashboard weeks later.
//   3. Top-level values survive log2logstash's type coercion unchanged.
//   4. Property names shared with feature:ai_review carry the same type.
//      The Logstash index is shared, so a name reused with a different type
//      collides on an Elasticsearch mapping that already exists.
//
// Sources of truth, read from GHES rather than assumed:
//   wpcom  wp-content/lib/log2logstash/log2logstash.php
//   wpcom  wp-content/rest-api-plugins/endpoints/ai-review-telemetry.php  (PR 219949)

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(readFileSync(join(HERE, 'event-schema.json'), 'utf8'));
// Optional argument points at an alternative examples file, which is how the
// negative fixtures in tests/telemetry-contract/ are driven.
const examplesPath = process.argv[2] ?? join(HERE, 'examples.json');
// A fixture holds one deliberately broken payload, so the coverage check
// below applies only to the declared set. Running it over a fixture would
// report all 17 outcomes as uncovered, and those errors alone would keep the
// run red after the defect the fixture exists to catch was fixed.
const isDeclaredSet = process.argv[2] === undefined;
const examples = JSON.parse(readFileSync(examplesPath, 'utf8'));

// ---------------------------------------------------------------------------
// log2logstash_allowed_parameters(), verbatim from the wpcom source.
// A key outside this list is unset() before the event is written.
// ---------------------------------------------------------------------------
const L2L_ALLOWED = new Set([
    'activity_timestamp', 'api_url', 'api_auth_hint', 'atomic_site_id', 'blog_id',
    'browser_name', 'browser_version', 'calypso_env', 'calypso_path', 'calypso_section',
    'client_id', 'comment_id', 'comment_type', 'commit', 'connection_id', 'datacenter',
    'destination_ip', 'dest', 'dest_target', 'ds_blog', 'duration', 'network_latency',
    'error_code', 'es_retention', 'extra', 'feature', 'file', 'host', 'http_response_code',
    'index', 'line', 'message', 'method', 'note_id', 'jetpack_version', 'hosting_provider',
    'plugin', 'path', 'post_id', 'properties', 'pid', 'plan_id', 'redirect_location',
    'request_id', 'score', 'severity', 'site_id', 'size', 'source', 'source_ip', 'success',
    'tags', 'devtags', 'tests', 'timestamp', 'trace', 'url', 'user_id', 'external_user_id',
    'user_locale', 'gt_id', 'job_type', 'job_id', 'job_priority', 'es_index', 'id', 'ids',
    'rule_matches',
]);

// The switch() in log2logstash__internal(). Everything not listed is cast to
// (string) when scalar, or var_export()'d when it is an array.
const L2L_CAST_FLOAT = new Set(['duration', 'score', 'lag_float', 'network_latency', 'openai_cost']);
const L2L_CAST_ARRAY = new Set(['ids', 'devtags', 'rule_matches', 'tags', 'properties']);
const L2L_CAST_INT = new Set([
    'queue_size', 'full_sync_items', 'atomic_site_id', 'blog_id', 'client_id', 'comment_id',
    'connection_id', 'ds_blog', 'note_id', 'post_id', 'user_id', 'size', 'http_response_code',
    'pid', 'id', 'job_priority', 'job_id', 'plan_id', 'site_id',
]);

// es_retention values the log2logstash source comment names, plus the ones
// confirmed in use. The comment is stale: 3m was granted as a retention in
// 2022, and ai_review ships it today.
//   https://systemsrequests.wordpress.com/2022/11/24/requesting-3-months-log-retention-for-card-testing-analysis/
const L2L_RETENTION_IN_SOURCE = new Set(['1d', '1w', '1m', '3m', '6m']);

// ---------------------------------------------------------------------------
// Types feature:ai_review already writes into properties, from the endpoint
// added in wpcom PR 219949. Shared names must match these exactly.
// ---------------------------------------------------------------------------
const AI_REVIEW_PROPERTY_TYPES = {
    source: 'string', outcome: 'string', repo: 'string', pr: 'string',
    pr_label: 'string', pr_author: 'string', model: 'string', is_followup: 'boolean',
    fail_reason: 'string', cost_usd: 'number', api_duration_ms: 'integer',
    num_turns: 'integer', tokens_in: 'integer', tokens_out: 'integer',
    cache_read: 'integer', cache_creation: 'integer', diff_bytes: 'integer',
    review_bytes: 'integer', pr_head_sha: 'string', before_sha: 'string',
    ci_provider: 'string', session_id: 'string', ttft_ms: 'integer',
};

// ai_review sends success through wp_json_encode( bool ), which yields these
// two strings. Matching them exactly keeps one mapping for the shared field.
const SUCCESS_TRUE = 'true';
const SUCCESS_FALSE = 'false';

const problems = [];
const notes = [];
const fail = (scenario, msg) => problems.push(`${scenario}: ${msg}`);

const typeOf = (v) => {
    if (v === null) return 'null';
    if (Array.isArray(v)) return 'array';
    if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
    return typeof v;
};

// An integer literal satisfies a "number" field. The reverse is not true.
const typeMatches = (actual, expected) =>
    actual === expected || (expected === 'number' && actual === 'integer');

// ---------------------------------------------------------------------------
// Check 1. Examples against the schema.
// ---------------------------------------------------------------------------
function checkSchema(scenario, body) {
    const spec = schema.fields;

    for (const [name, def] of Object.entries(spec)) {
        if (def.required && !(name in body)) fail(scenario, `missing required field ${name}`);
    }

    for (const [key, value] of Object.entries(body)) {
        const def = spec[key];
        if (!def) {
            fail(scenario, `field ${key} is not in the schema, so the endpoint allowlist would reject it with a 400`);
            continue;
        }
        if (value === null) {
            if (!def.nullable) fail(scenario, `field ${key} is null but the schema does not allow null`);
            continue;
        }
        if (!typeMatches(typeOf(value), def.type)) {
            fail(scenario, `field ${key} is ${typeOf(value)}, schema says ${def.type}`);
        }
        if (def.const !== undefined && value !== def.const) {
            fail(scenario, `field ${key} is ${JSON.stringify(value)}, schema pins it to ${JSON.stringify(def.const)}`);
        }
        if (def.enum && !def.enum.includes(value)) {
            fail(scenario, `field ${key} value ${JSON.stringify(value)} is outside ${JSON.stringify(def.enum)}`);
        }
        if (def.enum_ref && !(value in schema[def.enum_ref])) {
            fail(scenario, `field ${key} value ${JSON.stringify(value)} is not a declared ${def.enum_ref} key`);
        }
        if (def.pattern && !new RegExp(def.pattern).test(String(value))) {
            fail(scenario, `field ${key} value ${JSON.stringify(value)} fails pattern ${def.pattern}`);
        }
        if (def.minimum !== undefined && value < def.minimum) {
            fail(scenario, `field ${key} value ${value} is below minimum ${def.minimum}`);
        }
        if (def.maximum !== undefined && value > def.maximum) {
            fail(scenario, `field ${key} value ${value} is above maximum ${def.maximum}`);
        }
    }

    for (const name of schema.required_by_outcome[body.outcome] ?? []) {
        if (!(name in body)) fail(scenario, `outcome ${body.outcome} requires ${name}`);
    }
    for (const name of schema.forbidden_by_outcome[body.outcome] ?? []) {
        if (name in body) fail(scenario, `outcome ${body.outcome} must never carry ${name}`);
    }

    const declared = schema.outcomes[body.outcome];
    if (declared && declared.job !== body.job) {
        fail(scenario, `outcome ${body.outcome} belongs to job ${declared.job}, body says ${body.job}`);
    }

    const reasons = schema.fail_reasons[body.outcome];
    if (reasons && 'fail_reason' in body && !reasons.includes(body.fail_reason)) {
        fail(scenario, `fail_reason ${JSON.stringify(body.fail_reason)} is not declared for ${body.outcome}`);
    }
    if (!reasons && body.fail_reason) {
        fail(scenario, `outcome ${body.outcome} has no declared fail reasons but the body sets one`);
    }

    const bytes = Buffer.byteLength(JSON.stringify(body), 'utf8');
    if (bytes > schema.body_cap_bytes) {
        fail(scenario, `body is ${bytes} bytes, over the ${schema.body_cap_bytes} cap`);
    }
    return bytes;
}

// ---------------------------------------------------------------------------
// Reference implementation of the endpoint transform. The wpcom PR should
// produce exactly this shape.
// ---------------------------------------------------------------------------
function transform(body) {
    const declared = schema.outcomes[body.outcome];
    const properties = {};

    for (const [key, value] of Object.entries(body)) {
        const def = schema.fields[key];
        if (def?.destination === 'properties') properties[key] = value;
    }

    const event = {
        feature: body.feature,
        message: declared.message,
        severity: declared.severity,
        success: declared.success ? SUCCESS_TRUE : SUCCESS_FALSE,
        properties,
        index: 'log2logstash',
        es_retention: '3m',
    };

    if ('duration' in body) event.duration = body.duration;
    if ('pr_head_sha' in body) event.commit = body.pr_head_sha;
    if (typeof body.build_url === 'string' && body.build_url.startsWith('https://')) {
        event.url = body.build_url;
    }
    return event;
}

// ---------------------------------------------------------------------------
// Checks 2 and 3. Top-level keys and their survival through the cast switch.
// ---------------------------------------------------------------------------
function checkLogstashEvent(scenario, event) {
    for (const [key, value] of Object.entries(event)) {
        if (!L2L_ALLOWED.has(key)) {
            fail(scenario, `top-level key ${key} is not in log2logstash_allowed_parameters(), so it is silently dropped`);
            continue;
        }
        const actual = typeOf(value);
        if (L2L_CAST_FLOAT.has(key) && !['number', 'integer'].includes(actual)) {
            fail(scenario, `${key} is cast to float by log2logstash but the value is ${actual}`);
        } else if (L2L_CAST_INT.has(key) && actual !== 'integer') {
            fail(scenario, `${key} is cast to int by log2logstash but the value is ${actual}`);
        } else if (L2L_CAST_ARRAY.has(key) && !['array', 'object'].includes(actual)) {
            fail(scenario, `${key} is cast to array by log2logstash but the value is ${actual}`);
        } else if (!L2L_CAST_FLOAT.has(key) && !L2L_CAST_INT.has(key) && !L2L_CAST_ARRAY.has(key) && actual !== 'string') {
            fail(scenario, `${key} falls to the default (string) cast but the value is ${actual}, so it is stored stringified`);
        }
    }

    if (event.success !== SUCCESS_TRUE && event.success !== SUCCESS_FALSE) {
        fail(scenario, `success must be the string "${SUCCESS_TRUE}" or "${SUCCESS_FALSE}" to match ai_review's mapping, got ${JSON.stringify(event.success)}`);
    }
    if (!L2L_RETENTION_IN_SOURCE.has(event.es_retention)) {
        notes.push(`es_retention "${event.es_retention}" is not one of the values named in the log2logstash source comment (${[...L2L_RETENTION_IN_SOURCE].join(', ')}). The Field Guide documents it and ai_review ships it, so the comment looks stale. Worth confirming before relying on it.`);
    }
}

// ---------------------------------------------------------------------------
// Check 4. Shared property names must carry ai_review's types.
// ---------------------------------------------------------------------------
function checkSharedIndex(scenario, properties) {
    for (const [key, value] of Object.entries(properties)) {
        const existing = AI_REVIEW_PROPERTY_TYPES[key];
        if (!existing) continue;
        const actual = typeOf(value);
        if (!typeMatches(actual, existing)) {
            fail(scenario, `properties.${key} is ${actual} here but ${existing} in feature:ai_review, which shares this index`);
        }
    }
}

// ---------------------------------------------------------------------------
let checked = 0;
let maxBytes = 0;

for (const [scenario, body] of Object.entries(examples)) {
    if (scenario.startsWith('$')) continue;
    checked++;
    maxBytes = Math.max(maxBytes, checkSchema(scenario, body));
    if (!schema.outcomes[body.outcome]) continue;
    const event = transform(body);
    checkLogstashEvent(scenario, event);
    checkSharedIndex(scenario, event.properties);
}

// Every declared outcome needs an example, or the contract is untested.
if (isDeclaredSet) {
    for (const outcome of Object.keys(schema.outcomes)) {
        const covered = Object.values(examples).some((b) => b?.outcome === outcome);
        if (!covered) problems.push(`coverage: no example for declared outcome ${outcome}`);
    }
}

console.log(`Checked ${checked} example payloads against ${Object.keys(schema.outcomes).length} declared outcomes.`);
console.log(`Largest body ${maxBytes} bytes, cap ${schema.body_cap_bytes}.`);

if (notes.length) {
    console.log('\nTo confirm:');
    for (const n of new Set(notes)) console.log(`  - ${n}`);
}

if (problems.length) {
    console.log(`\n${problems.length} problem(s):`);
    for (const p of problems) console.log(`  - ${p}`);
    process.exit(1);
}

console.log('\nNo problems found.');
