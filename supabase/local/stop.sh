#!/usr/bin/env bash
docker rm -f sim-db sim-auth sim-rest >/dev/null 2>&1 || true
pkill -f 'supabase/local/fnrun.ts' 2>/dev/null || true; pkill -f 'node gateway.mjs' 2>/dev/null || true
echo stopped
