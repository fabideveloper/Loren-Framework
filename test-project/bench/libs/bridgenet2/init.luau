-- Package entry, the same layout BridgeNet2's own release.js builds for its standalone .rbxm:
-- this module holds src (the library) next to its three dependencies, which src reaches as
-- script.Parent.Parent.Parent.<Name>. Not upstream code: see PROVENANCE.md.
return require(script.src)
