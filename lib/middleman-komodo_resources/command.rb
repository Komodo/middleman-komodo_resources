require 'middleman-core/cli'
require 'middleman-blog/uri_templates'
require 'date'
require 'digest'
require 'contentful_middleman/commands/context'
require 'contentful_middleman/tools/backup'
require 'contentful_middleman/version_hash'
require 'contentful_middleman/import_task'
require 'contentful_middleman/local_data/store'
require 'contentful_middleman/local_data/file'
require 'github_api'
require 'yaml'
require 'base64'
require 'date'
require 'github/markup'
require 'mime/types'
require "resolv-replace.rb"

module Middleman
    module Cli
        class Resources < Thor
            include Thor::Actions

            MIDDLEMAN_LOCAL_DATA_FOLDER = 'data'

            check_unknown_options!

            namespace :resources
            desc 'resources', 'Import data from Komodo Resources'
            
            def self.source_root
                ENV['MM_ROOT']
            end

            # Tell Thor to exit with a nonzero exit code on failure
            def self.exit_on_failure?
                true
            end

            def resources
                @resources = []
                
                @github = Github.new do |c|
                    c.basic_auth = "#{ENV['GITHUB_ID']}:#{ENV['GITHUB_SECRET']}"
                    c.stack do |builder|
                        builder.use Faraday::HttpCache, store: Rails.cache
                    end
                end
                
                threads = []
                
                categories = get_github_yaml 'categories.yml'
                categories.each_with_index() do |category,i|
                    puts "\n\nProcessing category: #{category["name"]}"
                    threads[i] = Thread.new{parse_category(category)}
                end
                
                categories.each_with_index() do |category,i|
                    threads[i].join
                    categories[i] = threads[i].value
                end
                
                File.write "#{Dir.pwd}/data/resources/categories.yml", categories.to_yaml
                
                popular = @resources.sort_by { |v,k| v["stargazers_count"] || 0 }.reverse
                File.write "#{Dir.pwd}/data/resources/popular.yml", popular.to_yaml
                
                downloads = @resources.sort_by { |v,k| v["download_count"] || 0 }.reverse
                File.write "#{Dir.pwd}/data/resources/downloads.yml", downloads.to_yaml
                
                all = @resources.sort_by { |v,k| v["last_update"]}.reverse
                File.write "#{Dir.pwd}/data/resources/all.yml", all.to_yaml
            end
            
            private
            def get_github_yaml(file)
                data = @github.repos.contents.get 'Komodo', 'Packages', file
                contents = Base64.decode64 data["content"]
                return YAML.load contents 
            end
            
            def get_yaml(file)
                unless File.exists? "#{Dir.pwd}/data/resources" + file
                    return false
                end
                
                return YAML.load "#{Dir.pwd}/data/resources" + file
            end
        
            def parse_category(category)
                cached = get_yaml(category["resource"]) || {}
                config = get_github_yaml(category["resource"]) || {}
                resources = cached.merge config
                resources_min = {}
                
                category["resources"] = 0
                
                threads = {}
                
                resources.each() do |title,resource|
                    puts "\nCollecting data for #{title}"
                    threads[title] = Thread.new{parse_resource(title, resource, category, config)}
                end # resource.each
                
                resources.each() do |title,_|
                    
                    threads[title].join
                    _resource = threads[title].value
                    
                    if _resource
                        resources[title] = _resource
                        resources_min[title] = parse_resource_min(
                                                    Marshal.load(Marshal.dump(_resource)))
                        category["resources"] += 1
                    else
                        resources.delete(title)
                    end
                    
                end # resource.each
                
                unless File.directory?("#{Dir.pwd}/data/resources")
                    FileUtils.mkdir "#{Dir.pwd}/data/resources"
                end
                
                @resources += resources.values
                
                File.write "#{Dir.pwd}/data/resources/#{category["resource"]}",
                            resources.values.compact.sort_by { |v,k| v["last_update"] }.reverse.to_yaml
                            
                File.write "#{Dir.pwd}/data/resources/min_#{category["resource"]}",
                            resources_min.values.sort_by { |v,k| v["last_update"] }.reverse.to_yaml
                
                return category
                
            end
            
            def parse_resource_min(resource)
                #resource
                fields = ["id", "name", "full_name", "owner", "html_url",
                          "description", "fork", "created_at", "updated_at",
                          "pushed_at", "homepage", "stargazers_count",
                          "watchers_count", "has_issues", "has_downloads",
                          "forks_count", "open_issues_count", "default_branch",
                          "subscribers_count", "title", "releases", "last_update",
                          "is_github", "category", "download_count"]
                r = sanitize(resource, fields)
               
                # resource.owner
                fields = ["login", "id", "avatar_url", "html_url"]
                r["owner"] = sanitize(r["owner"], fields) if r.has_key? "owner"
                
                # resource.releases
                if r.has_key? "releases" and r["releases"]
                    fields = ["id", "name", "prerelease", "created_at",
                              "published_at","assets"]
                    r["releases"].each_with_index() do |v,i|
                        r["releases"][i] = sanitize(v, fields)
                        
                        # resource.releases.assets
                        if r["releases"][i].has_key? "assets" and r["releases"][i]["assets"]
                            _fields = ["id", "name", "content_type",
                                       "download_count", "browser_download_url"]
                            r["releases"][i]["assets"].each_with_index() do |_v,_i|
                                r["releases"][i]["assets"][_i] = sanitize(_v, _fields)
                            end
                            
                            # For XPI addons, extract the <em:version> from
                            # install.rdf. This version is used for tracking
                            # package updates.
                            begin
                                url = r["releases"][i]["assets"].first["browser_download_url"]
                                r["releases"][i]["version"] = extract_manifest_tag(url, 'version') if url =~ /\.xpi$/
                            rescue Exception => e
                            end
                        end
                        
                    end #releases loop
                    
                    # For XPI addons, extract the <em:id> from install.rdf.
                    # This ID is used for tracking package updates.
                    begin
                        url = r["releases"].first["assets"].first["browser_download_url"]
                        r["manifest_id"] = extract_manifest_tag(url, 'id') if url =~ /\.xpi$/
                    rescue Exception => e
                    end
                    
                end # has key releases
                
                return r
            end
            
            def parse_resource(title, resource, category, config)
                resource = parse_resource_basics(title, resource, config)
                resource["category"] = category
                
                # Retrieve repo and readme from github
                if resource["is_github"]
                    resource = parse_github_data(title, resource, config)
                    
                    unless resource
                        return false
                    end
                end
                
                # Parse readme with markup
                if resource.has_key? "readme"
                    begin
                        resource["readme"] = parse_readme(resource)
                    rescue Exception => e
                        puts "\nError parsing readme: #{e.message}"
                        resource.delete("readme")
                    end
                end
                
                return resource
            end
            
            def parse_readme(resource)
                unless resource.has_key? "readme"
                    return
                end
                
                readme = resource["readme"]
                filename = "readme.md"
                if readme.has_key? "name"
                    filename = readme["name"]
                end
                
                content = readme["content"].force_encoding("UTF-8")
                
                unless content
                    return readme
                end
                
                ext = File.extname(filename)
                if ext == "" or ext.downcase == ".txt"
                    readme["content"] = "<pre>" + content + "</pre>"
                    return readme
                end
                
                readme["content"] = GitHub::Markup.render( filename, content )

                if resource["is_github"] and resource.has_key? "html_url"
                    branch = "master"
                    if resource.has_key? "default_branch"
                        branch = resource["default_branch"]
                    end
                    
                    contents = readme["content"]
                    
                    linkPath = resource["html_url"] + "/blob/#{branch}/"
                    contents = contents.gsub(/<a href="(?!https?:\/\/)/, "<a href=\"#{linkPath}")
                    
                    imgPath = resource["html_url"] + "/raw/#{branch}/"
                    contents = contents.gsub(/<img src="(?!https?:\/\/)/, "<img src=\"#{imgPath}")
                    
                    # Github automatically fixes blob urls to raw for images,
                    # so we should too ...
                    imgPath = resource["html_url"] + "/raw/#{branch}/"
                    rx = /(<img src="https?:\/\/github.com\/[\w_-]+\/[\w_-]+)\/blob/
                    contents = contents.gsub(rx, "\\1/raw")
                    
                    readme["content"] = contents
                end
                
                return readme
            end
            
            def parse_resource_basics(title, resource, config)
                # title > url
                if resource.kind_of? String
                    full_name = resource.split("/").last(2).join("/")
                    url = resource
                    resource = {}
                    resource["html_url"] = url
                    resource["full_name"] = full_name
                    
                # title > mixed
                elsif resource.kind_of? Hash and resource.has_key? "html_url"
                    resource["full_name"] = resource["html_url"].split("/").last(2).join("/")
                end
                
                # Defaults
                resource["title"] = title
                resource["name"] = title
                resource["releases"] = false
                
                unless resource.has_key? "last_update"
                    if resource.has_key? "pushed_at"
                        resource["last_update"] = resource["pushed_at"]
                    elsif resource.has_key? "updated_at"
                        resource["last_update"] = resource["updated_at"]
                    else
                        resource["last_update"] = '2010-01-01T01:00:00Z'
                    end
                end
                
                begin
                    resource["last_update"] = DateTime.parse(resource["last_update"].to_s).iso8601()
                rescue TypeError => e
                    puts "\nError parsing last_update: #{resource["last_update"]} - #{e.message}"
                    resource["last_update"] = '2010-01-01T01:00:00Z'
                end
                
                # Check if this is a github resource
                resource["is_github"] = false
                if resource.has_key? "html_url"
                    host = URI.parse(resource["html_url"]).host.downcase
                    host = host.start_with?('www.') ? host[4..-1] : host
                    resource["is_github"] = host == "github.com"
                end
                
                if resource.has_key? "raw_url" and ! resource["is_github"]
                    raw = resource["raw_url"]
                    type = MIME::Types.type_for(File.basename(raw)).first
                    if type
                        type = type.content_type
                        resource["releases"] = [{
                            "id" => raw,
                            "name" => File.basename(raw),
                            "assets" => [{
                                "id" => raw,
                                "name" => File.basename(raw),
                                "content_type" => type,
                                "download_count" => 0,
                                "browser_download_url" => raw
                            }]
                        }]
                    end
                end
                
                return resource
            end
            
            def parse_github_data(title, resource, config)
                user, repo = resource["full_name"].split("/")
                
                # Base Data
                begin
                    # Merge resource data with data from GitHub
                    ghData = @github.repos.get user, repo
                    ghData = ghData.to_hash()
                    if ghData.has_key? "message" and ghData["message"] == "Moved Permanently"
                        msg = "\n--------------"
                        msg += "\nREDIRECTED: #{title} (#{resource["full_name"]}) has moved permanently, please update the yaml to use the new url"
                        msg += "\n--------------"
                        puts msg
                        return false
                    end
                    resource = ghData.merge resource
                    resource["last_update"] = resource["pushed_at"]
                rescue Github::Error::ServiceError, Faraday::ConnectionFailed, NoMethodError => e
                    puts "\nGH Data Error: #{e.message}"
                    puts "\nStripping resource '#{title}' from local database"
                    return false
                end
                
                # Readme
                unless config[title].kind_of? Hash and config[title].has_key? "readme"
                    begin
                        data = @github.repos.contents.readme(user, repo)
                        contents = Base64.decode64(data["content"])
                        resource["readme"] = { "content" => contents, "name" => data["name"] }
                    rescue Github::Error::ServiceError, Faraday::ConnectionFailed, NoMethodError => e
                        puts "\nError retrieving readme: #{e.message}"
                    end
                end
                
                # Releases
                begin
                    releases = @github.repos.releases.list user, repo
                    
                    resource["releases"] = []
                    resource["download_count"] = 0
                    exported = false
                    
                    releases.each() do |release|
                        resource["releases"].push release.to_hash()
                        release.assets.each() do |asset|
                            resource["download_count"] += asset["download_count"]
                            
                            begin
                                isKsf = asset["browser_download_url"][-4..-1].downcase() == '.ksf'
                                if ! exported and isKsf
                                    exported = true
                                    resource["ksf"] = parse_ksf(asset["browser_download_url"])
                                end
                            rescue Exception => ex
                                puts "\nError retrieving KSF (#{title}): #{ex.message}"
                            end
                        end
                    end
                rescue Github::Error::ServiceError, Faraday::ConnectionFailed, NoMethodError => e
                    puts "\nError retrieving releases (#{title}): #{e.message}"
                end
                
                return resource
            end
            
            def parse_ksf(url)
                require 'open-uri'
                require 'tempfile'

                file = Tempfile.new('ksf')
                file.close()
                
                stream = open(url)
                IO.copy_stream(stream, file.path)
                
                exporter = <<-eos

import json
export = locals()
_export = {}
for l in export.keys():
    if l in ["export", "_export"]:
        continue
    if isinstance(export[l],dict):
        _export[l] = export[l]

print json.dumps(_export)
                eos
                
                file = open(file.path, 'a')
                file.write(exporter)
                file.close()
                
                return `python2 #{file.path}`
                
            end
            
            ##
            # Returns metadata for the given +tag+ in an Addon XPI's install.rdf
            # manifest.
            def extract_manifest_tag(url, tag)
                require 'open-uri'
                require 'zip'
                begin
                    Zip::InputStream.open(open(url)) do |zip|
                        while f = zip.get_next_entry
                            if f.name == 'install.rdf'
                                content = zip.read.scan(/<em:#{tag}>([^<]+)/).first.first
                                content.force_encoding "UTF-8"
                                return content
                            end
                        end
                    end
                    raise "install.rdf not found or the xpi was unreadable by rubyzip"
                rescue Exception => e
                    puts "\nError parsing install.rdf for #{url}: #{e.message}"
                    raise
                end
            end
            
            def sanitize(ob, keys)
                _ob = {}
                
                ob.each do |k,v|
                    if keys.include? k
                        _ob[k] = v
                    end
                end
                
                return _ob
            end
                
        end # class
    end # module CLI
end # module Middleman
