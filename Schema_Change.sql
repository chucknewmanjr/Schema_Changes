/*
	disable trigger [tr_Schema_Change] on database;
	-- enable trigger [tr_Schema_Change] on database;
	drop trigger if exists [tr_Schema_Change] on database;
	drop view if exists [Tools].[vw_Schema_Change];
	-- DANGER: do not drop the Tools.Schema_Change tables. Loss of data!
*/

-- disable the trigger so that it doesn't fire while running this script.
if exists (select * from sys.triggers where name = 'tr_Schema_Change' and parent_class_desc = 'DATABASE')
	disable trigger [tr_Schema_Change] on database;

if SCHEMA_ID('Tools') is null exec ('create schema [Tools] authorization [dbo]');

if OBJECT_ID('[Tools].[Schema_Change_User]') is null
	create table [Tools].[Schema_Change_User] (
		Schema_Change_User_ID int not null identity constraint PK_Tools_Schema_Change_User primary key,
		Login_Name sysname null,
		[User_Name] sysname null,
		constraint UX_Tools_Schema_Change_User unique (Login_Name, [User_Name])
	);

if OBJECT_ID('[Tools].[Schema_Change_Object]') is null
	create table [Tools].[Schema_Change_Object] (
		Schema_Change_Object_ID int not null identity constraint PK_Tools_Schema_Change_Object primary key,
		[Schema_Name] sysname null,
		[Object_Name] sysname null,
		constraint UX_Tools_Schema_Change_Object unique ([Schema_Name], [Object_Name])
	);

if OBJECT_ID('[Tools].[Schema_Change]') is null
	create table [Tools].[Schema_Change] (
		Schema_Change_ID int not null identity
			constraint PK_Tools_Schema_Change primary key,
		Trigger_Event_Type int null,
		Post_Time datetime null, -- local
		Schema_Change_User_ID int null
			constraint FK_Tools_Schema_Change_User_ID
			references [Tools].[Schema_Change_User] (Schema_Change_User_ID),
		Schema_Change_Object_ID int null
			constraint FK_Tools_Schema_Change_Object_ID
			references [Tools].[Schema_Change_Object] (Schema_Change_Object_ID),
		Alter_Table_Action_List xml null,
		Command_Text nvarchar(MAX) null
	);
go

-- ----------------------------------------------------------------
-- Called by the [Tools].[vw_Schema_Validation] view.
--		SELECT TOP 100 * FROM [Tools].[vw_Schema_Change] ORDER BY 1 DESC
create or alter view [Tools].[vw_Schema_Change] as
	SELECT
		e.Schema_Change_ID,
		tet.[type_name],
		e.Post_Time,
		u.Login_Name,
		u.[User_Name],
		o.[Schema_Name] + '.' + o.[Object_Name] as [Object_Name],
		e.Command_Text,
		e.Alter_Table_Action_List
	FROM [Tools].[Schema_Change] e
	left join sys.trigger_event_types tet on e.Trigger_Event_Type = tet.[type]
	left join [Tools].[Schema_Change_User] u on e.Schema_Change_User_ID = u.Schema_Change_User_ID
	left join [Tools].[Schema_Change_Object] o on e.Schema_Change_Object_ID = o.Schema_Change_Object_ID
go

create or alter proc [Tools].[P_Find_Schema_Change] @Saught varchar(MAX) as
	SELECT 
		Post_Time, 
		[type_name], 
		Login_Name, 
		[Object_Name], 
		Command_Text, 
		Alter_Table_Action_List
	FROM [Tools].[vw_Schema_Change]
	where Command_Text like '%' + REPLACE(REPLACE(@Saught, '[', '[[]'), '_', '[_]') + '%'
		or [type_name] = @Saught
		or Login_Name = @Saught
		or [Object_Name] = @Saught
	order by Schema_Change_ID desc;
go

-- ----------------------------------------------------------------
-- This trigger fires for any change to the schema in this database.
-- It does 2 things:
-- 1 - Records the schema change
-- 2 - Run the validation proc if it exists
create or alter trigger [tr_Schema_Change] on database after DDL_DATABASE_LEVEL_EVENTS as
	set nocount on;

	declare
		@Event_Data XML = EVENTDATA(),
		@Event_Type_Name nvarchar(64),
		@Post_Time datetime,
		@Login_Name sysname,
		@User_Name sysname,
		@Schema_Name sysname,
		@Object_Name sysname,
		@Alter_Table_Action_List xml,
		@Command_Text nvarchar(MAX);

	select
		@Event_Type_Name = c.value('EventType[1]', 'nvarchar(64)'),
		@Post_Time = c.value('PostTime[1]', 'datetime'),
		@Login_Name = c.value('LoginName[1]', 'sysname'),
		@User_Name = c.value('UserName[1]', 'sysname'),
		@Schema_Name = c.value('SchemaName[1]', 'sysname'),
		@Object_Name = c.value('ObjectName[1]', 'sysname'),
		@Alter_Table_Action_List = c.query('AlterTableActionList/*'),
		@Command_Text = c.value('(TSQLCommand/CommandText)[1]', 'nvarchar(MAX)')
	from @Event_Data.nodes('EVENT_INSTANCE') t(c);

	insert [Tools].[Schema_Change_User] (Login_Name, [User_Name])
	select @Login_Name, @User_Name
	except
	select Login_Name, [User_Name] from [Tools].[Schema_Change_User] WITH (HOLDLOCK, UPDLOCK);

	insert [Tools].[Schema_Change_Object] ([Schema_Name], [Object_Name])
	select @Schema_Name, @Object_Name
	except
	select [Schema_Name], [Object_Name] from [Tools].[Schema_Change_Object] WITH (HOLDLOCK, UPDLOCK);

	insert [Tools].[Schema_Change] (
		Trigger_Event_Type,
		Post_Time,
		Schema_Change_User_ID,
		Schema_Change_Object_ID,
		Alter_Table_Action_List,
		Command_Text
	)
	select
		t.[type],
		@Post_Time,
		u.Schema_Change_User_ID,
		o.Schema_Change_Object_ID,
		@Alter_Table_Action_List,
		@Command_Text
	from sys.trigger_event_types t
	cross join [Tools].[Schema_Change_User] u
	cross join [Tools].[Schema_Change_Object] o
	where t.[type_name] = @Event_Type_Name
		and u.Login_Name = @Login_Name and u.[User_Name] = @User_Name
		and o.[Schema_Name] = @Schema_Name and o.[Object_Name] = @Object_Name;

	declare @Schema_Change_ID int = SCOPE_IDENTITY();

	-- ====================== --
	-- ===== VALIDATION ===== --
	declare @Proc_Name nvarchar(MAX) = '[Tools].[p_Validate_Schema]';
	declare @Instruction nvarchar(MAX) = CONCAT(@Proc_Name, ' ', @Schema_Change_ID);

	if OBJECT_ID(@Proc_Name) is not null exec (@Instruction);
	-- ====================== --
	-- ====================== --
go

if exists (select * from sys.triggers where name = 'tr_Schema_Change' and parent_class_desc = 'DATABASE')
	enable trigger [tr_Schema_Change] on database;
go
