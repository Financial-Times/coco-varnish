vcl 4.0;

import vsthrottle;
import basicauth;

# Default backend definition. Set this to point to your content server.
backend default {
    .host = "VARNISH_BACKEND_HOST";
    .port = "VARNISH_BACKEND_PORT";
}

backend notifications_push {
  .host = "VARNISH_BACKEND_HOST";
  .port = "NOTIFICATIONS_PUSH_PORT";
}

sub vcl_recv {
    # Remove all cookies; we don't need them, and setting cookies bypasses varnish caching.
    unset req.http.Cookie;

    if (req.url ~ "^\/robots\.txt$") {
        return(synth(200, "robots"));
    }

    if ((req.url ~ "^\/__health.*$") || (req.url ~ "^\/__gtg.*$")) {
        set req.http.Host = "aggregate-healthcheck";
        return (pass);
    } elseif ((req.url ~ "^.*\/__health.*$") || (req.url ~ "^.*\/__gtg.*$")) {
        return (pass);
    } elseif (!req.url ~ "^\/__[\w-]*\/.*$") {
        set req.http.Host = "HOST_HEADER";
        set req.http.X-VarnishPassThrough = "true";
    }

    if (req.url ~ "^\/content-preview.*$") {
        if (vsthrottle.is_denied(client.identity, 2, 1s)) {
    	    # Client has exceeded 2 reqs per 1s
    	    return (synth(429, "Too Many Requests"));
        }
    } elseif (req.url ~ "^\/(content|lists)\/notifications-push.*$") {
        set req.backend_hint = notifications_push;
        # Routing preset here as vulcan is unable to route on query strings
    } elseif (req.url ~ "\/content\?.*isAnnotatedBy=.*") {
        set req.http.Host = "public-content-by-concept-api";
    }

    if (!basicauth.match("/.htpasswd",  req.http.Authorization)) {
        return(synth(401, "Authentication required"));
    }

    #This checks if the user is a known B2B user and is trying to access the notifications-push endpoint.
    #If the B2B client calls another endpoint, other than notification-push, return 403 Forbidden
    if (req.http.Authorization ~ "^Basic QjJC[a-zA-Z0-9=]*") {
      if (req.url !~ "^\/content\/notifications-push.*$") {
              return (synth(403, "Forbidden"));
      }
      if (vsthrottle.is_denied(client.identity, 2, 1s)) {
        	  # Client has exceeded 2 reqs per 1s
        	  return (synth(429, "Too Many Requests"));
      }
    }

    if (req.url !~ "^\/(content|lists)\/notifications-push.*$") {
      unset req.http.Authorization;
    }
}

sub vcl_synth {
    if (resp.reason == "robots") {
        synthetic({"User-agent: *
Disallow: /"});
        return (deliver);
    }
    if (resp.status == 401) {
        set resp.http.WWW-Authenticate = "Basic realm=Secured";
        set resp.status = 401;
        return (deliver);
    }
}

sub vcl_backend_response {
    # Happens after we have read the response headers from the backend.
    #
    # Here you clean the response headers, removing silly Set-Cookie headers
    # and other mistakes your backend does.
    if (((beresp.status == 500) || (beresp.status == 502) || (beresp.status == 503) || (beresp.status == 504)) && (bereq.method == "GET" )) {
        if (bereq.retries < 2 ) {
            return(retry);
        }
    }
}

sub vcl_deliver {
    # Happens when we have all the pieces we need, and are about to send the
    # response to the client.
    #
    # You can do accounting or modifying the final object here.
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
