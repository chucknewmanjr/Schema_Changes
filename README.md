# Schema-Changes
This repository contains 4 Transact-SQL scripts. When used together, they do 2 things:
- They store all executed DDL instructions, which are also called schema changes.
- And they validate schema changes.
#Transact-SQL Scripts
- Schema-Change-Storage.sql - Creates tables, procs and such for storing schema changes. It's typically executed in 1 database. But can be executed in multtiple.
- Schema-Change-Transmission.sql - Creates a database level trigger that sends info for storage that's about the schema change. It also kicks off the validation process.
- Schema-Validation.sql - Creates a table, procs and such for performing validations. 

The Schema_Changes.sql script is for tracking schema or DDL changes. for searching, repeating and validating. DDL shanges are also called schema changes. They're different from table selects, inserts, updates and deletes. They typically include CREATE, ALTER or DROP.
## Installation
Executing the **schema-change-database.sql** script on a database sets up that database for storing schema changes. It does that by creating the SchemaChange schema and then creating tables, procs and a view in that schema. 

Executing the **schema-change-trigger.sql** script on a database sets up that databas for spotting schema chantges and requesting to have the change stored. It does that by creating a database trigger. It's different from your usual table trigger. A database must have been selected for storing schema changes before running this script.

Multiple databases can be used for storing schema changes. Here's how that works. When you execute **schema-change-trigger.sql**, it checks if the current database stores schema changes. If it does, then it stores its own schema changes in its own tables. So **schema-change-trigger.sql** can be executed on every database on which **schema-change-database.sql** has been executed. And they all store their own schema changes in their own tables.

## Installation Failures
**schema-change-trigger.sql** looks for the database in which if should store schema changes.
- **schema-change-database.sql** must be executed on a database before executing **schema-change-trigger.sql** on any database.
- If **schema-change-database.sql** is executed on multiple databases, then **schema-change-trigger.sql** can only be executed on those databases.

It can be executed on multiple databases. 
# Schema_Validation


# Notes
SQL Server has server triggers. This repo uses database triggers. Plus, the data is stored on the same database as the trigger. This means that if you drop that database, you lose the data. If the data is stored in a separate database (say Schema_Changes) then there's another interesting feature to be added. Let's day you back up a database on monday, make a bunch of DDL changes and then drop the database on friday. You could restore the backup and then replay all those changes. I chose not to do that so that this repo works in Azure. At the time, Azure SQL database did not allow for cross database queries. It turns out most shops still develop on on-prem SQL Server. 

# Scripts
- **Schema_Change.sql** - This can be used without Schema_Validation. It creates tables, a trigger and more for recording all DDL changes.
- **Schema_Validation.sql** - Adds validation onto Schema_Change.sql. It displays warnings if the DDL change violates any rules.
- **Schema_Validation_Rules.sql** - This contains a base set of rules.

# future changes
- the changes should be stored in a separate database on the server. ([Tools])
- The [Tools].[Schema_Change_Object] table gets a database name column.
- The db trigger should go into each database that gets tracked. 
- Those triggers must write the database name into [Tools].[Schema_Change_Object].
These changes mean this project wont work in azure. I think that's OK since teams usually develop on-prem.
