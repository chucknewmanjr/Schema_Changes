-- ----------------------------------------------------------------------------
-- ===== INSTRUCTIONS ===== --
-- Run this script in each database to have schema changes recorded.
-- It creates a database trigger that fires for any schema change.
-- ----------------------------------------------------------------------------

-- Avoid accidentally firing the trigger for these schema changes.
if exists (select * from sys.triggers where name = 't_SchemaChange')
	DISABLE TRIGGER [t_SchemaChange] ON DATABASE;
GO

declare @DatabaseNames table (DatabaseName sysname);

-- Check the current database first.
insert @DatabaseNames 
select db_name() 
from sys.procedures 
where object_id = OBJECT_ID('[SchemaChange].[p_Save]');

-- If this database dosn't save schema changes, go check the others.
if @@ROWCOUNT = 0
	insert @DatabaseNames 
	exec sp_MSforeachdb '
		use [?]; 
		select db_name() 
		from sys.procedures 
		where object_id = OBJECT_ID(''SchemaChange.p_Save'');
	';

-- This instruction fails if there's more than one.
declare @DatabaseName sysname = (select * from @DatabaseNames);

if @DatabaseName is null throw 50000, 'No designated schema change database found.', 1;

declare @TriggerTemplate nvarchar(MAX) = '
-- ----------------------------------------------------------------------------
-- This trigger fires for any schema change in the current database.
-- The event gets saved in the designated schema change database.
create or alter trigger [t_SchemaChange] 
on database after DDL_DATABASE_LEVEL_EVENTS 
as
	declare @DatabaseName sysname = db_name();
	declare @EventData xml = EVENTDATA();
	declare @EventID int;

	exec @EventID = [[DatabaseName]].[SchemaChange].[p_Save] 
		@DatabaseName=@DatabaseName, 
		@EventData=@EventData;

	-- ===== VALIDATION ===== --
	declare @ProcName nvarchar(MAX) = ''[SchemaValidation].[p_ValidateSchema]'';
	declare @SQLInstruction nvarchar(MAX) = CONCAT(
		@ProcName, 
		'' @DatabaseName=''''[DatabaseName]'''','',
		'' @EventID='', @EventID, '';''
	);

	if OBJECT_ID(@ProcName) is not null exec (@SQLInstruction);
';

set @TriggerTemplate = REPLACE(@TriggerTemplate, '[DatabaseName]', @DatabaseName);

exec (@TriggerTemplate);

ENABLE TRIGGER [t_SchemaChange] ON DATABASE
GO


