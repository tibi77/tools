/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (c) 1999-2017 by Digital Mars, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/ddmd/dimport.d, _dimport.d)
 */

module ddmd.dimport;

// Online documentation: https://dlang.org/phobos/ddmd_dimport.html

import core.stdc.string;
import core.stdc.stdio;

import ddmd.arraytypes;
import ddmd.declaration;
import ddmd.dmodule;
import ddmd.dscope;
import ddmd.dsymbol;
import ddmd.errors;
import ddmd.expression;
import ddmd.globals;
import ddmd.hdrgen;
import ddmd.id;
import ddmd.identifier;
import ddmd.mtype;
import ddmd.root.outbuffer;
import ddmd.utils;
import ddmd.visitor;

/***********************************************************
 */
extern (C++) final class Import : Dsymbol
{
    /* static import aliasId = pkg1.pkg2.id : alias1 = name1, alias2 = name2;
     */
    Identifiers* packages;  // array of Identifier's representing packages
    Identifier id;          // module Identifier
    Identifier aliasId;
    int isstatic;           // !=0 if static import
    Prot protection;

    // Pairs of alias=name to bind into current namespace
    Identifiers names;
    Identifiers aliases;

    Module mod;
    Package pkg;            // leftmost package/module

    // corresponding AliasDeclarations for alias=name pairs
    AliasDeclarations aliasdecls;

    extern (D) this(Loc loc, Identifiers* packages, Identifier id, Identifier aliasId, int isstatic)
    {
        super(null);
        assert(id);
        version (none)
        {
            printf("Import::Import(");
            if (packages && packages.dim)
            {
                for (size_t i = 0; i < packages.dim; i++)
                {
                    Identifier id = (*packages)[i];
                    printf("%s.", id.toChars());
                }
            }
            printf("%s)\n", id.toChars());
        }
        this.loc = loc;
        this.packages = packages;
        this.id = id;
        this.aliasId = aliasId;
        this.isstatic = isstatic;
        this.protection = PROTprivate; // default to private
        // Set symbol name (bracketed)
        if (aliasId)
        {
            // import [cstdio] = std.stdio;
            this.ident = aliasId;
        }
        else if (packages && packages.dim)
        {
            // import [std].stdio;
            this.ident = (*packages)[0];
        }
        else
        {
            // import [foo];
            this.ident = id;
        }
    }

    void addAlias(Identifier name, Identifier _alias)
    {
        if (isstatic)
            error("cannot have an import bind list");
        if (!aliasId)
            this.ident = null; // make it an anonymous import
        names.push(name);
        aliases.push(_alias);
    }

    override const(char)* kind() const
    {
        return isstatic ? cast(char*)"static import" : cast(char*)"import";
    }

    override Prot prot()
    {
        return protection;
    }

    // copy only syntax trees
    override Dsymbol syntaxCopy(Dsymbol s)
    {
        assert(!s);
        auto si = new Import(loc, packages, id, aliasId, isstatic);
        for (size_t i = 0; i < names.dim; i++)
        {
            si.addAlias(names[i], aliases[i]);
        }
        return si;
    }

    void load(Scope* sc)
    {
        //printf("Import::load('%s') %p\n", toPrettyChars(), this);
        // See if existing module
        DsymbolTable dst = Package.resolve(packages, null, &pkg);
        version (none)
        {
            if (pkg && pkg.isModule())
            {
                .error(loc, "can only import from a module, not from a member of module %s. Did you mean `import %s : %s`?", pkg.toChars(), pkg.toPrettyChars(), id.toChars());
                mod = pkg.isModule(); // Error recovery - treat as import of that module
                return;
            }
        }
        Dsymbol s = dst.lookup(id);
        if (s)
        {
            if (s.isModule())
                mod = cast(Module)s;
            else
            {
                if (s.isAliasDeclaration())
                {
                    .error(loc, "%s %s conflicts with %s", s.kind(), s.toPrettyChars(), id.toChars());
                }
                else if (Package p = s.isPackage())
                {
                    if (p.isPkgMod == PKGunknown)
                    {
                        mod = Module.load(loc, packages, id);
                        if (!mod)
                            p.isPkgMod = PKGpackage;
                        else
                        {
                            // mod is a package.d, or a normal module which conflicts with the package name.
                            assert(mod.isPackageFile == (p.isPkgMod == PKGmodule));
                            if (mod.isPackageFile)
                                mod.tag = p.tag; // reuse the same package tag
                        }
                    }
                    else
                    {
                        mod = p.isPackageMod();
                    }
                    if (!mod)
                    {
                        .error(loc, "can only import from a module, not from package %s.%s", p.toPrettyChars(), id.toChars());
                    }
                }
                else if (pkg)
                {
                    .error(loc, "can only import from a module, not from package %s.%s", pkg.toPrettyChars(), id.toChars());
                }
                else
                {
                    .error(loc, "can only import from a module, not from package %s", id.toChars());
                }
            }
        }
        if (!mod)
        {
            // Load module
            mod = Module.load(loc, packages, id);
            if (mod)
            {
                // id may be different from mod.ident, if so then insert alias
                dst.insert(id, mod);
            }
        }
        if (mod && !mod.importedFrom)
            mod.importedFrom = sc ? sc._module.importedFrom : Module.rootModule;
        if (!pkg)
            pkg = mod;
        //printf("-Import::load('%s'), pkg = %p\n", toChars(), pkg);
    }

    override void importAll(Scope* sc)
    {
        if (!mod)
        {
            load(sc);
            if (mod) // if successfully loaded module
            {
                if (mod.md && mod.md.isdeprecated)
                {
                    Expression msg = mod.md.msg;
                    if (StringExp se = msg ? msg.toStringExp() : null)
                        mod.deprecation(loc, "is deprecated - %s", se.string);
                    else
                        mod.deprecation(loc, "is deprecated");
                }
                mod.importAll(null);
                if (sc.explicitProtection)
                    protection = sc.protection;
                if (!isstatic && !aliasId && !names.dim)
                {
                    sc.scopesym.importScope(mod, protection);
                }
            }
        }
    }

    override void semantic(Scope* sc)
    {
        //printf("Import::semantic('%s') %s\n", toPrettyChars(), id.toChars());
        if (semanticRun > PASSinit)
            return;

        if (_scope)
        {
            sc = _scope;
            _scope = null;
        }
        if (!sc)
            return;

        semanticRun = PASSsemantic;

        // Load if not already done so
        if (!mod)
        {
            load(sc);
            if (mod)
                mod.importAll(null);
        }
        if (mod)
        {
            // Modules need a list of each imported module
            //printf("%s imports %s\n", sc.module.toChars(), mod.toChars());
            sc._module.aimports.push(mod);

            if (sc.explicitProtection)
                protection = sc.protection;

            if (!aliasId && !names.dim) // neither a selective nor a renamed import
            {
                ScopeDsymbol scopesym;
                for (Scope* scd = sc; scd; scd = scd.enclosing)
                {
                    if (!scd.scopesym)
                        continue;
                    scopesym = scd.scopesym;
                    break;
                }

                if (!isstatic)
                {
                    scopesym.importScope(mod, protection);
                }

                // Mark the imported packages as accessible from the current
                // scope. This access check is necessary when using FQN b/c
                // we're using a single global package tree.
                // https://issues.dlang.org/show_bug.cgi?id=313
                if (packages)
                {
                    // import a.b.c.d;
                    auto p = pkg; // a
                    scopesym.addAccessiblePackage(p, protection);
                    foreach (id; (*packages)[1 .. packages.dim]) // [b, c]
                    {
                        p = cast(Package) p.symtab.lookup(id);
                        scopesym.addAccessiblePackage(p, protection);
                    }
                }
                scopesym.addAccessiblePackage(mod, protection); // d
            }

            mod.semantic(null);
            if (mod.needmoduleinfo)
            {
                //printf("module4 %s because of %s\n", sc.module.toChars(), mod.toChars());
                sc._module.needmoduleinfo = 1;
            }

            sc = sc.push(mod);
            sc.protection = protection;
            for (size_t i = 0; i < aliasdecls.dim; i++)
            {
                AliasDeclaration ad = aliasdecls[i];
                //printf("\tImport %s alias %s = %s, scope = %p\n", toPrettyChars(), aliases[i].toChars(), names[i].toChars(), ad._scope);
                if (mod.search(loc, names[i]))
                {
                    ad.semantic(sc);
                    // If the import declaration is in non-root module,
                    // analysis of the aliased symbol is deferred.
                    // Therefore, don't see the ad.aliassym or ad.type here.
                }
                else
                {
                    Dsymbol s = mod.search_correct(names[i]);
                    if (s)
                        mod.error(loc, "import '%s' not found, did you mean %s '%s'?", names[i].toChars(), s.kind(), s.toChars());
                    else
                        mod.error(loc, "import '%s' not found", names[i].toChars());
                    ad.type = Type.terror;
                }
            }
            sc = sc.pop();
        }

        semanticRun = PASSsemanticdone;

        // object self-imports itself, so skip that
        // https://issues.dlang.org/show_bug.cgi?id=7547
        // don't list pseudo modules __entrypoint.d, __main.d
        // https://issues.dlang.org/show_bug.cgi?id=11117
        // https://issues.dlang.org/show_bug.cgi?id=11164
        if (global.params.moduleDeps !is null && !(id == Id.object && sc._module.ident == Id.object) &&
            sc._module.ident != Id.entrypoint &&
            strcmp(sc._module.ident.toChars(), "__main") != 0)
        {
            /* The grammar of the file is:
             *      ImportDeclaration
             *          ::= BasicImportDeclaration [ " : " ImportBindList ] [ " -> "
             *      ModuleAliasIdentifier ] "\n"
             *
             *      BasicImportDeclaration
             *          ::= ModuleFullyQualifiedName " (" FilePath ") : " Protection|"string"
             *              " [ " static" ] : " ModuleFullyQualifiedName " (" FilePath ")"
             *
             *      FilePath
             *          - any string with '(', ')' and '\' escaped with the '\' character
             */
            OutBuffer* ob = global.params.moduleDeps;
            Module imod = sc.instantiatingModule();
            if (!global.params.moduleDepsFile)
                ob.writestring("depsImport ");
            ob.writestring(imod.toPrettyChars());
            ob.writestring(" (");
            escapePath(ob, imod.srcfile.toChars());
            ob.writestring(") : ");
            // use protection instead of sc.protection because it couldn't be
            // resolved yet, see the comment above
            protectionToBuffer(ob, protection);
            ob.writeByte(' ');
            if (isstatic)
            {
                stcToBuffer(ob, STCstatic);
                ob.writeByte(' ');
            }
            ob.writestring(": ");
            if (packages)
            {
                for (size_t i = 0; i < packages.dim; i++)
                {
                    Identifier pid = (*packages)[i];
                    ob.printf("%s.", pid.toChars());
                }
            }
            ob.writestring(id.toChars());
            ob.writestring(" (");
            if (mod)
                escapePath(ob, mod.srcfile.toChars());
            else
                ob.writestring("???");
            ob.writeByte(')');
            for (size_t i = 0; i < names.dim; i++)
            {
                if (i == 0)
                    ob.writeByte(':');
                else
                    ob.writeByte(',');
                Identifier name = names[i];
                Identifier _alias = aliases[i];
                if (!_alias)
                {
                    ob.printf("%s", name.toChars());
                    _alias = name;
                }
                else
                    ob.printf("%s=%s", _alias.toChars(), name.toChars());
            }
            if (aliasId)
                ob.printf(" -> %s", aliasId.toChars());
            ob.writenl();
        }
        //printf("-Import::semantic('%s'), pkg = %p\n", toChars(), pkg);
    }

    override void semantic2(Scope* sc)
    {
        //printf("Import::semantic2('%s')\n", toChars());
        if (mod)
        {
            mod.semantic2(null);
            if (mod.needmoduleinfo)
            {
                //printf("module5 %s because of %s\n", sc.module.toChars(), mod.toChars());
                if (sc)
                    sc._module.needmoduleinfo = 1;
            }
        }
    }

    override Dsymbol toAlias()
    {
        if (aliasId)
            return mod;
        return this;
    }

    /*****************************
     * Add import to sd's symbol table.
     */
    override void addMember(Scope* sc, ScopeDsymbol sd)
    {
        //printf("Import.addMember(this=%s, sd=%s, sc=%p)\n", toChars(), sd.toChars(), sc);
        if (names.dim == 0)
            return Dsymbol.addMember(sc, sd);
        if (aliasId)
            Dsymbol.addMember(sc, sd);
        /* Instead of adding the import to sd's symbol table,
         * add each of the alias=name pairs
         */
        for (size_t i = 0; i < names.dim; i++)
        {
            Identifier name = names[i];
            Identifier _alias = aliases[i];
            if (!_alias)
                _alias = name;
            auto tname = new TypeIdentifier(loc, name);
            auto ad = new AliasDeclaration(loc, _alias, tname);
            ad._import = this;
            ad.addMember(sc, sd);
            aliasdecls.push(ad);
        }
    }

    override void setScope(Scope* sc)
    {
        Dsymbol.setScope(sc);
        if (aliasdecls.dim)
        {
            if (!mod)
                importAll(sc);

            sc = sc.push(mod);
            sc.protection = protection;
            foreach (ad; aliasdecls)
                ad.setScope(sc);
            sc = sc.pop();
        }
    }

    override Dsymbol search(Loc loc, Identifier ident, int flags = SearchLocalsOnly)
    {
        //printf("%s.Import.search(ident = '%s', flags = x%x)\n", toChars(), ident.toChars(), flags);
        if (!pkg)
        {
            load(null);
            mod.importAll(null);
            mod.semantic(null);
        }
        // Forward it to the package/module
        return pkg.search(loc, ident, flags);
    }

    override bool overloadInsert(Dsymbol s)
    {
        /* Allow multiple imports with the same package base, but disallow
         * alias collisions
         * https://issues.dlang.org/show_bug.cgi?id=5412
         */
        assert(ident && ident == s.ident);
        Import imp;
        if (!aliasId && (imp = s.isImport()) !is null && !imp.aliasId)
            return true;
        else
            return false;
    }

    override inout(Import) isImport() inout
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }
}