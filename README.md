 # Schema-Changes
This repository is specifically for Microsoft SQL Server. It contains 4 Transact-SQL scripts. When used together, they do 2 things:
- They store all executed DDL instructions, which are also called schema changes.
- And they validate schema changes.

# Transact-SQL Scripts
- **Schema-Change-Storage.sql** - Creates tables, procs and such for storing schema changes. It's typically executed in 1 database. But can be executed in multtiple.
- **Schema-Change-Transmission.sql** - Creates a database level trigger that sends info for storage that's about the schema change. It also kicks off the validation process.
- **Schema-Validation.sql** - Creates a table, procs and such for performing validations.
- **Schema-Validation-Rules.sql** - Inserts the rules used for the validation process.

# Installation
Before we get to writing rules and handling violations, let's try to get this thing running.
### Step 1 - Schema-Change-Storage.sql
Typically, the schema changes are stored in a single database such as Utility or Tools. In that case, the Schema-Change-Storage.sql script is executed in only that database. However, it's also possible to have each database store their own schema changes. In that case, changes are not combined into a single database.
### Step 2 - Schema-Change-Transmission.sql
Execute this script on each database from which you want schema changes stored. That can include the databases that store changes. If there's more than one database that stores changes, then it con only be executed on those databases.
### Step 3 - Schema-Validation.sql
Validation is optional. Execute this script on any database that transmits schema changes. Validation will not occur until rules are inserted.
### Step 4 - Schema-Validation-Rules.sql
This script inserts 30+ rules. Some might be useful to you. These instructions can help you write more.





# Potential Instalation Issues
- If there's more than one database that stores schema changes and Schema-Change-Transmission.sql is executed on a database that does not store schema changes, then an error occurs. That's because the trigger doesn't know where to send changes. Either install Schema-Change-Storage.sql in the database or uninstall SchemaChange from all but one database. But be careful. Uninstalling SchemaChange might cause a significant data loss.
- If Schema-Change-Transmission.sql is executed before there's any database to store schema changes, it fails. Run Schema-Change-Storage.sql first.
- If you run Schema-Change-Storage.sql on a second database, no schema changes will get saved there until you run Schema-Change-Transmission.sql on that same database.

# Uninstall
Here's what to drop:
- Database level triggers - If you're only uninstalling validation, don't drop these triggers. For each database in SSMS, navigate to Programmability > Database Triggers. The trigger is named "t_SchemaChange".
- SchemaValidation schema - All of the validation is in this schema. For each database, drop the procs (6), table (1) and a scalar function (1). Then drop the schema.
- SchemaChanges schema - Careful dropping the tables (3) in this schema. It could cause a significant loss of data. Beyond that, drop procs (2) and a view (1). Then you can drop the schema.


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
