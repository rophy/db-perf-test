#!/usr/bin/tclsh
# HammerDB TPROC-C Schema Delete Script for PostgreSQL/YugabyteDB

puts "=== HammerDB TPROC-C Schema Delete ==="

# Database configuration
dbset db pg
dbset bm TPC-C

# Connection settings from environment variables
set pg_host [expr {[info exists ::env(PG_HOST)] ? $::env(PG_HOST) : "yb-tserver-service"}]
set pg_port [expr {[info exists ::env(PG_PORT)] ? $::env(PG_PORT) : "5433"}]
set pg_superuser [expr {[info exists ::env(PG_SUPERUSER)] ? $::env(PG_SUPERUSER) : "yugabyte"}]
set pg_superpass [expr {[info exists ::env(PG_SUPERPASS)] ? $::env(PG_SUPERPASS) : "yugabyte"}]
set pg_defaultdbase [expr {[info exists ::env(PG_DEFAULTDBASE)] ? $::env(PG_DEFAULTDBASE) : "yugabyte"}]
set pg_user [expr {[info exists ::env(PG_USER)] ? $::env(PG_USER) : "tpcc"}]
set pg_dbase [expr {[info exists ::env(PG_DBASE)] ? $::env(PG_DBASE) : "tpcc"}]

puts "Configuration:"
puts "  Host: $pg_host:$pg_port"
puts "  Superuser: $pg_superuser"
puts "  Database to delete: $pg_dbase"
puts "  User to delete: $pg_user"

# PostgreSQL connection settings
diset connection pg_host $pg_host
diset connection pg_port $pg_port

# TPROC-C settings for deletion
diset tpcc pg_superuser $pg_superuser
diset tpcc pg_superuserpass $pg_superpass
diset tpcc pg_defaultdbase $pg_defaultdbase
diset tpcc pg_user $pg_user
diset tpcc pg_dbase $pg_dbase

# Delete schema
puts "\nDeleting schema..."
deleteschema

puts "\n=== Schema Delete Complete ==="
