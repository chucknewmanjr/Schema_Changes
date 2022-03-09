# Schema_Changes
Track DDL changes for searching, repeating and validating

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
