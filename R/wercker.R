add_wercker_build_pipeline = function(app_id)
{
  req = httr::POST(
    "https://app.wercker.com/api/v3/pipelines",
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json",
    body = list(
      application = app_id,
      name = "build",
      permissions = "public",
      pipelineName = "build",
      setScmProviderStatus = TRUE,
      type = "git"
    )
  )
  httr::stop_for_status(req)

  res = httr::content(req)
  stopifnot(!is.null(res$id))

  res$id
}

add_wercker_app = function(repo, org_id, privacy = c("public", "private"), provider = "github")
{
  privacy = match.arg(privacy)

  req = httr::POST(
    "https://app.wercker.com/api/v2/applications",
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json",
    body = list(
      owner = org_id,
      privacy = privacy,
      scmName = get_repo_name(repo),
      scmOwner = get_repo_owner(repo),
      scmProvider = provider,
      stack = "6" # Docker
    )
  )
  httr::stop_for_status(req)

  res = httr::content(req)
  stopifnot(!is.null(res$success))

  app_id = res$data$id

  is_private = gh("GET /repos/:owner/:repo",
                  owner=get_repo_owner(repo),
                  repo = get_repo_name(repo),
                  .token = get_github_token())$private

  if (is_private) # setup a deploy key for private repos
  {
    add_wercker_deploy_key(repo, app_id)
  }

  pipeline_id = add_wercker_build_pipeline(app_id)
  run_id = run_wercker_pipeline(pipeline_id)

  invisible(NULL)
}

run_wercker_pipeline = function(pipeline_id)
{
  req = httr::POST(
    "https://app.wercker.com/api/v3/runs",
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json",
    body = list(
      pipelineId = pipeline_id
    )
  )
  httr::stop_for_status(req)
  res = httr::content(req)
  stopifnot(!is.null(res$id))

  res$id
}

get_wercker_deploy_key = function()
{
  req = httr::POST(
    paste0("https://app.wercker.com/api/v2/checkoutKeys"),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json"
  )
  httr::stop_for_status(req)
  httr::content(req)
}

add_key_to_github = function(repo, key_id, provider = "github")
{
  req = httr::POST(
    paste0("https://app.wercker.com/api/v2/checkoutKeys/",key_id,"/link"),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json",
    body = list(
      scmName = get_repo_name(repo),
      scmOwner = get_repo_owner(repo),
      scmProvider = provider
    )
  )
  httr::stop_for_status(req)
  res = httr::content(req)
  stopifnot(!is.null(res$success))
}

add_key_to_app = function(app_id, key_id, type="unique")
{
  req = httr::POST(
    paste0("https://app.wercker.com/api/v2/applications/",app_id,"/checkoutKey"),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json",
    body = list(
      checkoutKeyId = key_id,
      checkoutKeyType = type
    )
  )
  httr::stop_for_status(req)
  res = httr::content(req)
  stopifnot(!is.null(res$success))
}

add_wercker_deploy_key = function(repo, app_id, provider = "github")
{
  key = get_wercker_deploy_key()
  add_key_to_github(repo, key$id, provider)
  add_key_to_app(app_id, key$id)
}

#' @export
get_wercker_whoami = function()
{
  req = httr::GET(
    paste0("https://app.wercker.com/api/v2/profile"),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json"
  )
  httr::stop_for_status(req)
  res = httr::content(req, as="text")
  jsonlite::fromJSON(res)
}

#' @export
get_wercker_orgs = function()
{
  req = httr::GET(
    paste0("https://app.wercker.com/api/v2/users/me/organizations"),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json"
  )
  httr::stop_for_status(req)

  res = httr::content(req, as="text")
  res = jsonlite::fromJSON(res)
  res[-which(names(res) == "allowedActions")]
}

#' @export
get_wercker_apps = function(owner)
{
  req = httr::GET(
    paste0("https://app.wercker.com/api/v3/applications/", owner, "?limit=100"),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json"
  )
  httr::stop_for_status(req)
  res = httr::content(req, as="text")
  jsonlite::fromJSON(res)
}

get_wercker_org_id = function(org)
{
  orgs = get_wercker_orgs()
  orgs = orgs[orgs$username == org,]

  if (nrow(orgs) != 1)
    stop("Unable to find organization called ", org, " on wercker.", call. = FALSE)

  orgs[["id"]]
}

get_wercker_app_id = function(repo)
{
  app = purrr::map(repo, get_wercker_app_info)
  purrr::map_chr(app, "id")
}


get_wercker_app_info = function(repo)
{
  stopifnot(length(repo) == 1)
  require_valid_repo(repo)

  req = httr::GET(
    paste0("https://app.wercker.com/api/v3/applications/", repo),
    httr::add_headers(
      Authorization = paste("Bearer", get_wercker_token())
    ),
    encode = "json"
  )
  httr::stop_for_status(req)
  httr::content(req)
}





#' @export
add_wercker = function(repo, wercker_org, add_badge=TRUE, verbose=TRUE)
{
  require_valid_repo(repo)
  org_id = get_wercker_org_id(wercker_org)

  existing_apps = get_wercker_apps(wercker_org)[["name"]]

  purrr::walk(
    repo,
    function(repo) {
      if (get_repo_name(repo) %in% existing_apps) {
        if (verbose)
          cat("Skipping, app already exists for", repo, "...\n")
        return()
      }

      if (verbose)
        cat("Creating wercker app for", repo, "...\n")

      add_wercker_app(repo, org_id)
      if (add_badge)
        add_wercker_badge(repo)
    }
  )
}



get_wercker_badge_key = function(repo)
{
  app_info = purrr::map(repo, get_wercker_app_info)
  purrr::map_chr(app_info, "badgeKey")
}

#' @export
get_wercker_badge = function(repo, size = "small", type = "markdown", branch = "master")
{
  size = match.arg(size, c("small", "large"), several.ok = TRUE)
  type = match.arg(type, c("markdown", "html"), several.ok = TRUE)

  size = switch(
    size,
    small = "s",
    large = "m"
  )

  key = get_wercker_badge_key(repo)

  purrr::pmap_chr(
    list(size, type, key, branch),
    function(size, type, key, branch) {
      img_url = sprintf("https://app.wercker.com/status/%s/%s/%s", key, size, branch)
      app_url = sprintf("https://app.wercker.com/project/byKey/%s", key)

      if (type == "markdown")
        sprintf('[![wercker status](%s "wercker status")](%s)', img_url, app_url)
      else
        sprintf('<a href="%s"><img alt="Wercker status" src="%s"></a>', app_url, img_url)
    }
  )
}


strip_existing_badge = function(content)
{
  md_badge_pattern = "\\[\\!\\[wercker status\\]\\(.*? \"wercker status\"\\)\\]\\(.*?\\)\n*"
  html_badge_pattern = "<a href=\".*?\"><img alt=\"Wercker status\" src=\".*?\"></a>"

  content = gsub(md_badge_pattern, "", content)
  content = gsub(html_badge_pattern, "", content)
}





#' @export
add_wercker_badge = function(repo, badge = get_wercker_badge(repo, branch = branch),
                             branch = "master", message = "Adding wercker badge",
                             strip_existing_badge = TRUE, verbose = TRUE)
{
  require_valid_repo(repo)

  res = purrr::pmap(
    list(repo, badge, branch, message),
    function(repo, badge, branch, message) {

      if (verbose)
        message("Adding badge to ", repo, " ...")

      readme = get_readme(repo, branch)

      if (is.null(readme)) { # README.md does not exist
        content = paste0(badge,"\n\n")
        gh_file = "README.md"
      } else {
        cur_readme = rawToChar(base64enc::base64decode(readme$content))
        if (strip_existing_badge)
          cur_readme = strip_existing_badge(cur_readme)

        gh_file = purrr::pluck(readme,"path")
        content = paste0(badge, "\n\n", cur_readme)
      }

      put_file(repo, gh_file, charToRaw(content), message, branch)
    }
  )

  purrr::walk2(
    repo[check_errors(res)], get_errors(res),
    function(repo, error) {
      msg = sprintf("Adding badge to %s failed.\n", repo)
      if (verbose) {
        bad_repos = paste0(repo, ": ", error)
        msg = paste0(msg, format_list(bad_repos))
      }

      warning(msg, call. = FALSE, immediate. = TRUE)
    }
  )
}







#' @export
add_wercker_env_var = function(repo, key, value, protected=FALSE)
{
  id = purrr::pmap_chr(
    list(repo, key, value, protected),
    function(repo, key, value, protected=TRUE) {
      req = httr::POST(
        "https://app.wercker.com/api/v3/envvars",
        httr::add_headers(
          Authorization = paste("Bearer", get_wercker_token())
        ),
        encode = "json",
        body = list(
          key       = as.character(key),
          protected = protected,
          scope     = "application",
          target    = get_wercker_app_id(repo),
          value     = as.character(value)
        )
      )

      httr::stop_for_status(req)

      purrr::pluck(httr::content(req), "id", .default = NA)
    }
  )

  invisible(id)
}


#' @export
get_wercker_env_vars = function(repo)
{
  require_valid_repo(repo)

  purrr::map2_df(
    repo, get_wercker_app_id(repo),
    function(repo, id)
    {
      req = httr::GET(
        paste0("https://app.wercker.com/api/v3/envvars?scope=application&target=", id),
        httr::add_headers(
          Authorization = paste("Bearer", get_wercker_token())
        ),
        encode = "json"
      )
      httr::stop_for_status(req)

      c(
        repo = repo,
        repo_id = id,
        purrr::pluck(httr::content(req), "results", 1L)
      )
    }
  )
}
