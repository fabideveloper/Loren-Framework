-- Unit-spec fixture: a ModuleScript whose require always fails. Registry.spec and Lifecycle.spec
-- clone it to check that a module failing to load is reported; Roblox prints this error in the
-- Output when a clone is required (expected). The collector skips "_" folders and only requires
-- modules named *.spec, so this never runs on its own.
error(
	"(LORENঌ - TEST) intentional load error: a spec checks that a module failing to load is reported (expected in the Output)",
	0
)
