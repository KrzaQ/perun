module pierun.webinterface;

import std.conv, std.format, std.string, std.typecons;

import vibe.d;
import vibe.web.auth;

import hibernated.core;

import pierun.core, pierun.dbcache, pierun.utils.misc;

struct SessionData
{
    bool loggedIn = false;
    string userName;
    string sessionId;
}

struct AuthInfo
{
    string userName;
    bool admin;

    @safe:
    bool isAdmin() const { return this.admin; }
}

struct BlogInfo
{
    DBCache dbCache;
    string pageTitle;

    auto getSetting(T)(const string key, const T defaultValue = T.init) {
        auto kv = dbCache.getValue(key);
        if(kv is null) {
            return defaultValue;
        } else {
            return kv.value.to!T;
        }
    }
}

@requiresAuth
class WebInterface
{
    private {
        DataSource dataSource;
        DBSession session;
        DBCache dbCache;
        AdminWebInterface adminWebInterface;
    }

    @property AdminWebInterface admin() { return adminWebInterface; }
    
    @noRoute
    AuthInfo authenticate(HTTPServerRequest req, HTTPServerResponse res){
        if (!req.session || !req.session.isKeySet("auth"))
            throw new HTTPStatusException(HTTPStatus.forbidden, "Not authorized to perform this action!");

        return req.session.get!AuthInfo("auth");
    }

    this(DataSource ds, DBSession s)
    {
        this.dataSource = ds;
        this.session = s;
        this.dbCache = new DBCache(s);
        this.adminWebInterface = new AdminWebInterface(this);
    }
    
    @noAuth
    void index(HTTPServerRequest req, HTTPServerResponse res)
    {
        Post[] posts = session
            .createQuery("FROM Post WHERE status = 0")
            .list!Post;

        render!("index.dt", posts);
    }

    @noAuth
    void getLogin(HTTPServerRequest req, string _error = null)
    {
        string page_title = "login";
        render!("login.dt", _error);
    }

    @noAuth @errorDisplay!getLogin 
    void postLogin(string username, string password,
        scope HTTPServerRequest req, scope HTTPServerResponse res)
    {
        auto user = session.createQuery("FROM User WHERE name=:Name")
            .setParameter("Name", username)
            .uniqueResult!User;

        enforceHTTP(user !is null,
            HTTPStatus.forbidden, "Username or password incorrect");

        import botan.passhash.bcrypt;

        enforceHTTP(checkBcrypt(password ~ user.salt, user.hashedPassword),
            HTTPStatus.forbidden, "Username or password incorrect");

        AuthInfo ai;
        ai.userName = user.name;
        ai.admin = true;
        req.session = res.startSession;
        req.session.set("auth", ai);

        redirect("/");
    }

    //@noAuth
    //void post(HTTPServerRequest req, string markdown)
    //{
    //    import pierun.utils.markdown;
    //    import std.conv;

    //    markdown = pierun.utils.markdown.parseMarkdown(markdown);

    //    render!("index.dt", markdown);
    //}

    @path("/post/:id/*") @noAuth @errorDisplay!error
    void getPostIdName(scope HTTPServerRequest req, scope HTTPServerResponse res)
    {
        auto id = req.params["id"].to!int;

        Post p = dbCache.getPost(id);

        enforceHTTP(p !is null, HTTPStatus.notFound,
            "Post %d not found!".format(id));

        if(p.status == Post.Status.Private) {
            auto auth = req.getAuth;

            enforceHTTP(!auth.isNull && auth.isAdmin, HTTPStatus.notFound,
                "Post %d not found!".format(id));
        }

        import std.stdio, std.algorithm;
        session.refresh(p.edits[$-1]);
        writefln("Tags: %s", p.edits[$-1].tags.map!(e => e.name).join(", "));

        render!("post.dt", p);
    }

    @path("/post/:id") @noAuth @errorDisplay!error
    void getPostId(scope HTTPServerRequest req, scope HTTPServerResponse res)
    {
        getPostIdName(req, res);
    }

    @auth(Role.admin)
    void getAddPost(HTTPServerRequest req, HTTPServerResponse res)
    {
        postAddPost(req, res);
    }

    @auth(Role.admin)
    void postAddPost(HTTPServerRequest req, HTTPServerResponse res,
        string markdown = "", string excerpt = "", string title = "",
        string language = "EN", string tags = "", string _error = null)
    {
        render!("add_post.dt", markdown, excerpt,
                title, language, tags, _error);
    }

    @auth(Role.admin) @errorDisplay!postAddPost
    void postSendPost(HTTPServerRequest req, HTTPServerResponse res,
        AuthInfo ai, string markdown, string excerpt, string title,
        string language, string tags)
    {
        enforceHTTP(language.length == 2, HTTPStatus.badRequest,
            "Language must be two characters long");

        import std.array, std.algorithm, std.regex, std.traits;

        auto getOrMakeTag = delegate Tag(const string name) {
            import std.stdio;
            writefln("working on tag: %s", name);
            auto t = dbCache.getTag(name);
            if(t is null) {
                t = new Tag;
                t.name = name;
                t.slugName = name.toSlugForm;
                session.save(t);
            }
            return t;
        };

        auto splitTags = tags
            .split(ctRegex!`,\s+`)
            .map!(identity!getOrMakeTag)
            .array;


        User u = session.createQuery("FROM User WHERE name=:Name")
            .setParameter("Name", ai.userName)
            .uniqueResult!User;

        Post p = new Post;
        PostData pd = new PostData;

        p.author = u;
        p.edits = [pd];
        p.published = cast(DateTime)Clock.currTime;

        pd.title = title;
        pd.markdown = markdown;
        pd.excerpt = excerpt;
        pd.timestamp = p.published;
        pd.post = p;
        pd.tags = splitTags;

        u.posts ~= p;

        session.update(u);
        session.save(p);
        session.save(pd);

        redirect("/");
    }


    @noRoute @noAuth
    void error(HTTPServerRequest req, string _error)
    {
        render!("error.dt", _error);
    }

    mixin PrivateAccessProxy;
}

Nullable!AuthInfo getAuth(ref HTTPServerRequest req) {
    Nullable!AuthInfo auth;
    if (req.session && req.session.isKeySet("auth"))
        auth = req.session.get!AuthInfo("auth");
    return auth;
}

Nullable!string getTime(ref HTTPServerRequest req) {
    Nullable!string ret;
    import std.conv;
    auto diff = Clock.currTime - req.timeCreated;
    ret = diff.to!string;
    return ret;
}

@requiresAuth
class AdminWebInterface
{
    private {
        WebInterface parent;
    }

    this(WebInterface wi) {
        parent = wi;
    }

    @noRoute
    auto authenticate(HTTPServerRequest req, HTTPServerResponse res)
    {
        return parent.authenticate(req, res);
    }

    @auth(Role.admin)
    void getSettingsRaw(HTTPServerRequest req, HTTPServerResponse res)
    {
        postSettingsRaw(req, res);
    }

    @auth(Role.admin)
    void postSettingsRaw(HTTPServerRequest req, HTTPServerResponse res)
    {
        foreach(k, v; req.form) {
            if(!k.startsWith("value_"))
                continue;
            parent.dbCache.setValue(k[6..$], v);
        }

        if(req.form.get("new_key").length > 0 &&
           req.form.get("new_value").length > 0) {
            parent.dbCache.setValue(req.form["new_key"], req.form["new_value"]);
        }

        auto kvs = parent.session
            .createQuery("FROM KeyValue")
            .list!KeyValue;

        render!("admin/settings.dt", kvs);
    }

}
