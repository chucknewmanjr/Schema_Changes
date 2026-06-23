 # Schema-Changes
This repository is specifically for Microsoft SQL Server. It contains 4 Transact-SQL scripts. When used together, they do 2 things:
- They store all executed DDL instructions, which are also called schema changes.
- And they validate schema changes.

# Terms
- **DDL** - Data Definition language statements typically start with CREATE, ALTER and DROP. These are the instructions that make changes the the structure and routines in a database. They're also called schema changes. They don't start with SELECT, INSERT, UPDATE and DELETE.
- **Schema** - The word schema has 2 meanings in the context of a database. It means both the structure of the database and a grouping of the objects in a database. For instance, the default schema is "dbo". The scripts in this repo create 2 more schemas named "SchemaChanges" and "SchemaValidation". Any CREATE, ALTER and DROP instructions executed on any of those schemas are considered schema changes.

# Transact-SQL Scripts
- **Schema-Change-Storage.sql** - Creates tables, procs and such for storing schema changes. It's typically executed in 1 database. But can be executed in multiple.
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

# Potential Installation Issues
- If there's more than one database that stores schema changes and Schema-Change-Transmission.sql is executed on a database that does not store schema changes, then an error occurs. That's because the trigger doesn't know where to send changes. Either install Schema-Change-Storage.sql in the database or uninstall SchemaChange from all but one database. But be careful. Uninstalling SchemaChange might cause a significant data loss.
- If Schema-Change-Transmission.sql is executed before there's any database to store schema changes, it fails. Run Schema-Change-Storage.sql first.
- If you run Schema-Change-Storage.sql on a second database, no schema changes will get saved there until you run Schema-Change-Transmission.sql on that same database.

# Uninstall
Here's what to drop:
- Database level triggers - If you're only uninstalling validation, don't drop these triggers. For each database in SSMS, navigate to Programmability > Database Triggers. The trigger is named "t_SchemaChange".
- SchemaValidation schema - All of the validation is in this schema. For each database, drop the procs (6), table (1) and a scalar function (1). Then drop the schema.
- SchemaChanges schema - Careful dropping the tables (3) in this schema. It could cause a significant loss of data. Beyond that, drop procs (2) and a view (1).

# Using Schema Changes
There's a view in the database that stores schema changes. It's called [SchemaChange].[v_SchemaChange]. 
`SELECT TOP (100) * FROM [SchemaChange].[v_SchemaChange] ORDER BY 1 DESC;`

# Handling Schema Validation Rule Violations
Rule violations include a rule code. It looks something like "DEFAULT-NAMING-1". 
- **Step 1** - Typically, schema change scripts have multiple commands. One command could cause a rule violation and then the violation gets corrected by subsiquent commands. So run the following instruction and check the status. If it's SUCCESS, then the violation has been resolved.
```
EXEC [SchemaValidation].[p_GetResults] 'DEFAULT-NAMING-1';
```
- **Step 2** - If none of the latest results are actually violations, run this:
```
EXEC [SchemaValidation].[p_SetExpectedResultsToLatest] 'DEFAULT-NAMING-1';
```
- **Step 3** - Make additional schema changes to correct the issue and rerun the rule.
```
EXEC [SchemaValidation].[p_ValidateRule] 'DEFAULT-NAMING-1';
EXEC [SchemaValidation].[p_GetResults] 'DEFAULT-NAMING-1';
```
- **Step 4** - Update the CommandText of the rule to allow more conditions and rerun the rule.

# Writing Schema Validation Rules
The Schema-Validation-Rules.sql script is full of good examples. It calls the [SchemaValidation].[p_SetRule] proc repeatedly to insert or update rules. That proc takes 3 parameters
- RuleCode - A Short recognisable text like "DEFAULT-NAMING-1". It must be unique.
- FailureMessage - The message displayed to the user when the rule is violated.
- CommandText - SQL instruction that returns a row of useful info if a violation is found.

### How this functions
The results of executing CommandText is compared to ExpectedResults. If a row is not found in ExpectedResults, then the rule status is set to "FAILURE". 

### System tables commonly used in rule command text:
| System Table | System Table |
| -- | -- |
| sys.objects | INFORMATION_SCHEMA.COLUMNS |
| sys.tables | INFORMATION_SCHEMA.TABLE_CONSTRAINTS |
| sys.columns | sys.default_constraints |
| sys.foreign_keys | sys.foreign_key_columns |
| sys.indexes | sys.sql_dependencies |
| sys.index_columns |  |

### System functions commonly used in rule command text:
- OBJECT_NAME(object_id)
- OBJECT_SCHEMA_NAME(object_id)
- SCHEMA_NAME(schema_id)
- COL_NAME(object_id, column_id)
- TYPE_NAME(user_type_id)
- OBJECTPROPERTY(object_id, 'IsTable')
- COLUMNPROPERTY(object_id, 'ColumnName', 'IsIdentity')




