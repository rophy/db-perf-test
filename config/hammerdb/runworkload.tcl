#!/usr/bin/tclsh
# HammerDB TPROC-C Workload Script for PostgreSQL/YugabyteDB

puts "=== HammerDB TPROC-C Workload ==="

# Database configuration
dbset db pg
dbset bm TPC-C

# Connection settings from environment variables
set pg_host [expr {[info exists ::env(PG_HOST)] ? $::env(PG_HOST) : "yb-tserver-service"}]
set pg_port [expr {[info exists ::env(PG_PORT)] ? $::env(PG_PORT) : "5433"}]
set pg_user [expr {[info exists ::env(PG_USER)] ? $::env(PG_USER) : "tpcc"}]
set pg_pass [expr {[info exists ::env(PG_PASS)] ? $::env(PG_PASS) : "tpcc"}]
set pg_dbase [expr {[info exists ::env(PG_DBASE)] ? $::env(PG_DBASE) : "tpcc"}]
set vus [expr {[info exists ::env(HAMMERDB_VUS)] ? $::env(HAMMERDB_VUS) : "4"}]
set duration [expr {[info exists ::env(HAMMERDB_DURATION)] ? $::env(HAMMERDB_DURATION) : "5"}]
set rampup [expr {[info exists ::env(HAMMERDB_RAMPUP)] ? $::env(HAMMERDB_RAMPUP) : "1"}]

puts "Configuration:"
puts "  Host: $pg_host:$pg_port"
puts "  Database: $pg_dbase"
puts "  User: $pg_user"
puts "  Virtual Users: $vus"
puts "  Duration: $duration minutes"
puts "  Rampup: $rampup minutes"

# PostgreSQL connection settings
diset connection pg_host $pg_host
diset connection pg_port $pg_port

# TPROC-C driver settings
diset tpcc pg_driver timed
diset tpcc pg_rampup $rampup
diset tpcc pg_duration $duration
diset tpcc pg_user $pg_user
diset tpcc pg_pass $pg_pass
diset tpcc pg_dbase $pg_dbase

# Enable all transaction types
diset tpcc pg_allwarehouse false
diset tpcc pg_timeprofile false

# Load driver script
loadscript

puts "\nStarting virtual users..."
vuset vu $vus
vucreate
vurun

puts "\n=== Workload started - waiting for completion ==="
# Wait for virtual users to finish
runtimer [expr {($rampup + $duration + 1) * 60}]

puts "\n=== Workload Complete ==="
vudestroy
