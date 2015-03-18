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
                @github = Github.new basic_auth: "#{ENV['GITHUB_ID']}:#{ENV['GITHUB_SECRET']}"
                
                categories = get_github_yaml 'categories.yml'
                categories.each_with_index() do |category,i|
                    puts "\nProcessing category: #{category["name"]}"
                    categories[i] = parse_category(category)
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
                data = @github.repos.contents.get 'Komodo', 'Komodo-Resources', file, ref: 'ko9'
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
                
                category["resources"] = 0
                
                resources.each() do |title,resource|
                    
                    puts "Collecting data for #{title}"
                    
                    resource = parse_resource_basics(title, resource, config)
                    resource["category"] = category
                    
                    # Retrieve repo and readme from github
                    if resource["is_github"]
                        resource = parse_github_data(title, resource, config)
                        
                        unless resource
                            # Something went wrong, remove this resource from generated data
                            resources.delete(title)
                            next
                        end
                    end
                    
                    # Parse readme with markup
                    if resource.has_key? "readme"
                        begin
                            filename = "readme.md"
                            if resource["readme"].has_key? "name"
                                filename = resource["readme"]["name"]
                            end
                            resource["readme"]["content"] = GitHub::Markup.render(
                                                                filename,
                                                                resource["readme"]["content"].force_encoding("UTF-8") )
                        rescue Exception => e
                            puts "Error parsing readme: #{e.message}"
                            resource.delete("readme")
                        end
                    end
                    
                    resources[title] = resource
                    category["resources"] += 1
                    
                end # resource.each
                
                unless File.directory?("#{Dir.pwd}/data/resources")
                    FileUtils.mkdir "#{Dir.pwd}/data/resources"
                end
                
                @resources += resources.values
                
                File.write "#{Dir.pwd}/data/resources/#{category["resource"]}",
                            resources.values.sort_by { |v,k| v["last_update"] }.reverse.to_yaml
                
                return category
                
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
                    puts "Error parsing last_update: #{resource["last_update"]} - #{e.message}"
                    resource["last_update"] = '2010-01-01T01:00:00Z'
                end
                
                # Check if this is a github resource
                resource["is_github"] = false
                if resource.has_key? "html_url"
                    host = URI.parse(resource["html_url"]).host.downcase
                    host = host.start_with?('www.') ? host[4..-1] : host
                    resource["is_github"] = host == "github.com"
                end
                
                return resource
            end
            
            def parse_github_data(title, resource, config)
                user, repo = resource["full_name"].split("/")
                
                # Base Data
                begin
                    # Merge resource data with data from GitHub
                    ghData = @github.repos.get user, repo
                    resource = ghData.to_hash().merge resource
                    resource["last_update"] = resource["pushed_at"]
                rescue Github::Error::ServiceError => e
                    puts "Error: #{e.message}"
                    puts "Stripping resource from local database"
                    return false
                end
                
                # Readme
                unless config[title].kind_of? Hash and config[title].has_key? "readme"
                    begin
                        data = @github.repos.contents.readme(user, repo)
                        contents = Base64.decode64(data["content"])
                        resource["readme"] = { "content" => contents, "name" => data["name"] }
                    rescue Github::Error::ServiceError => e
                        puts "Error retrieving readme: #{e.message}"
                    end
                end
                
                # Releases
                begin
                    releases = @github.repos.releases.list user, repo
                    
                    resource["releases"] = []
                    resource["download_count"] = 0
                    
                    releases.each() do |release|
                        resource["releases"].push release.to_hash()
                        release.assets.each() do |asset|
                            resource["download_count"] += asset["download_count"]
                        end
                    end
                rescue Github::Error::ServiceError => e
                    puts "Error retrieving releases: #{e.message}"
                end
                
                return resource
            end
                
        end # class
    end # module CLI
end # module Middleman