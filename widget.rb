#this is a list of all of the methods ancestry gem 1.3.0 adds
HAS_ANCESTRY_METHODS = [:ancestor_conditions, :ancestor_ids, :ancestors, :ancestry_callbacks_disabled?, :ancestry_column, :ancestry_column=, :ancestry_exclude_self, :apply_orphan_strategy, :base_class, :base_class=, :cache_depth, :child_ancestry, :child_conditions, :child_ids, :children, :depth, :descendant_conditions, :descendant_ids, :descendants, :has_children?, :has_siblings?, :is_childless?, :is_only_child?, :is_root?, :orphan_strategy, :parent, :parent=, :parent_id, :parent_id=, :path, :path_conditions, :path_ids, :rails_3, :rails_3=, :root, :root_id, :sibling_conditions, :sibling_ids, :siblings, :subtree, :subtree_conditions, :subtree_ids, :update_descendants_with_new_ancestry, :without_ancestry_callbacks]

class Widget < ActiveRecord::Base
  include Tire::Model::Search
  include Tire::Model::Callbacks
  include ERB::Util

  attr_accessible :name, :fields, :templates, :tag_list,
    :css_class, :javascript, :super_widget_id, :cached_tag_list, :search_tag_list,
    :ancestry_cache, :deep_fields, :deep_fields_hash, :deep_templates_hash, :last_worked_on

  belongs_to :super_widget, class_name: 'Widget'
  has_many   :ancestors, foreign_key: 'child_id',  class_name: 'WidgetAncestry', :dependent => :destroy
  has_many   :progeny,   foreign_key: 'parent_id', class_name: 'WidgetAncestry', :dependent => :destroy
  has_many   :parents,   through: :ancestors, class_name: 'Widget'
  has_many   :children,  through: :progeny,  class_name: 'Widget'
  has_one :page

  before_save :set_hidden_to_false

  # scope has_ancestry with "inheritance_", don't overwrite :children
  alias :tmp_ancestors :ancestors
  alias :tmp_children  :children
  alias :tmp_child_ids :child_ids
  has_ancestry orphan_strategy: :rootify
  HAS_ANCESTRY_METHODS.each do |old_method|
    #This is here to prevent collision with the ancestry gem methods
    new_method = "inheritance_#{old_method.to_s}"
    eval "alias :#{new_method} :#{old_method}"
  end
  alias :ancestors :tmp_ancestors
  alias :children  :tmp_children
  alias :child_ids :tmp_child_ids
  alias :old_super_widget :super_widget
  alias_attribute :old_super_widget_id, :super_widget_id
  alias :super_widget     :inheritance_parent
  alias :super_widget_id  :inheritance_parent_id
  alias :super_widget=    :inheritance_parent=
  alias :super_widget_id= :inheritance_parent_id=

  acts_as_taggable
  acts_as_taggable_on :search_tags

  serialize :fields, Array
  serialize :templates, Array
  serialize :deep_fields, Array
  serialize :deep_fields_hash, Hash
  serialize :deep_templates_hash, Hash
  serialize :ancestry_cache, Hash

  liquid_methods :children, :fields, :deep_fields_hash, :name, :to_s, :html, :css, :javascript, :id, :data

  def content_page(widget = self)
    if widget
      parent = widget.parents.first
      if parent && parent.page
        return parent.page
      else
        return widget.content_page(widget.parents.first)
      end
    end
  end

  def all_parents
    self.parents.inject(self.parents) { |result, w| result += w.all_parents }
  end

  def all_children
    self.children.inject(self.children) { |result, w| result += w.all_children }
  end

  def visible_children
    self.children.select do |c|
      c.deep_fields_hash["visible"] != "false"
    end
  end

  def recache_children
    self.all_children.each do |child|
      child.cache_deep_fields_and_templates(nil, {do_save: true})
    end

    self.cache_deep_fields_and_templates(nil, {do_save: true})
  end

  def recache_all
    self.cache_ancestry(recache_parents:true,recache_children:true,do_save:true)
    self.cache_deep_fields_and_templates(nil, {do_save:true, recache_children:true})
  end

  def included_in_pages
    return [self.page] if self.page
    result  = self.all_parents.map(&:page)
    result += self.inheritance_descendants.inject([]){ |r,w| r + w.included_in_pages }
    result.compact.uniq
  end

  def propagate_fields_and_templates
    descendants = [self] + self.inheritance_descendants
    cached_widgets = descendants + self.inheritance_ancestors
    self.last_worked_on = Time.now
    descendants.each do |widget|
      widget.cache_deep_fields_and_templates(cached_widgets, do_save: true)
    end
  end

  def cache_deep_fields_and_templates(cached_widgets = nil, options = {})
    self.deep_fields_hash = self.get_deep_fields_hash(cached_widgets)
    self.deep_fields = self.get_deep_fields(cached_widgets)
    self.deep_templates_hash = self.get_deep_templates_hash(cached_widgets)
    self.save if options[:do_save]
  end

  def save_fields(fields)
    self.fields = fields
    self.save
  end

  def cache_ancestry(options = {do_save: true, recache_parents: true})
    self.ancestry_cache ||= {}

    descendants = { widgets: [self.id], relations: self.progeny_ids }
    self.ancestry_cache[:descendants] = self.children.inject(descendants) do |result, w|
      get_ancestry = !w.ancestry_cache || w.ancestry_cache.empty? || !w.ancestry_cache[:descendants]
      get_ancestry ||= options[:recache_children] && options[:do_save]
      child_ancestry = get_ancestry ? w.cache_ancestry(options.merge(recache_parents: false)) : w.ancestry_cache
      result[:widgets] += child_ancestry[:descendants][:widgets] || []
      result[:widgets]  = result[:widgets].uniq
      #result[:relations] ||= []
      #result[:relations]  += child_ancestry[:descendants][:relations] || []
      result
    end
    self.save if options[:do_save]

    options_for_parent = options.merge(recache_children: false, recache_parents: true)
    self.parents.map { |p| p.cache_ancestry(options_for_parent) } if options[:recache_parents] && options[:do_save]

    self.ancestry_cache
  end

  def as_json(options = {})
    if options[:context] == :page_admin
      options[:only] ||= []
      options[:only].push(:id, :name)
      result = super(options)
      templates = self.deep_templates_hash
      return result.merge(
        tag_list: self.cached_tag_list,
        read_only: {
          created_at: result.delete('created_at'),
          updated_at: result.delete('updated_at'),
          deep_fields: self.deep_fields,
          deep_templates: templates
        }
      )
    end

    slim = options.delete(:slim)
    if slim
      options[:only] ||= []
      options[:only].push(:id, :name, :super_widget_id)
    end

    include_fields_hash = options.delete(:fields_hash)
    if include_fields_hash
      options[:only] ||= []
      options[:only].push(:deep_fields_hash)
    end

    result = super(options)
    deep_fields = result.delete('deep_fields')
    deep_templates = result.delete('deep_templates_hash')
    deep_fields_hash = result.delete('deep_fields_hash')

    # delete params that should not be updated, move them into 'read_only'
    read_only = {}
    read_only[:deep_fields_hash] = deep_fields_hash if include_fields_hash
    read_only.merge!(
      created_at: result.delete('created_at'),
      updated_at: result.delete('updated_at'),
      deep_fields: deep_fields,
      deep_templates: deep_templates,
      inheritance_descendants: self.inheritance_descendants.select(['widgets.id', 'widgets.name']).map { |d| {id: d.id, name: d.name} },
      affects_pages: self.included_in_pages.map { |p| {id: p.id, title: p.title, url: p.url} },
      parents: self.parents.select(['widgets.id', 'widgets.name']).map { |p| {id: p.id, name: p.name} }
    ) unless slim

    result.merge(
      tag_list: self.cached_tag_list,
      read_only: read_only
    )
  end

  def add_child(child_id, options = { as: 'reference', prefix: nil })
    child = Widget.find(child_id)

    case options[:as]
    when 'duplicate', 'subwidget'
      new_child = child.copy_with_children(options[:as], options[:prefix])
    else # reference
      new_child = child
    end

    self.progeny.create(child_id: new_child.id, copy_as: options[:as])
  end

  def copy_with_children(copy_as = 'duplicate', prefix = nil)
    if copy_as == 'subwidget'
      new_widget = Widget.new(super_widget_id: self.id, name: "#{prefix || "Sub-widget of "}#{self.name}")
    else # duplicate
      new_widget = self.dup
      new_widget.name = "#{prefix || "Copy of "}#{self.name}"
    end
    new_widget.save
    # Copy children to new widget according to the copy_as parameter...
    child_prefix = "#{new_widget.name}: "
    self.progeny.each do |progeny|
      case progeny.copy_as
      when :duplicate
        child = progeny.child.copy_with_children('duplicate', child_prefix)
      when :reference
        child = progeny.child
      else # :subwidget
        child = progeny.child.copy_with_children('subwidget', child_prefix)
      end
      new_widget.progeny.create(child_id: child.id, copy_as: progeny.copy_as)
    end

    new_widget.cache_deep_fields_and_templates(nil, {do_save:true, recache_children:true})
    new_widget

  end

  # --- templating methods --- #
  def html(view = 'main')
    template = self.template(view)
    return "" unless template

    html = Liquid::Template.parse(template['liquid']).render(self.liquid_data)
    html.html_safe
  end

  def scss(view = 'main')
    template = self.template(view)
    return "" unless template
    scss = template['scss'] || template['sass']
    Liquid::Template.parse(scss).render(self.liquid_data)
  end

  def deep_scss(view = 'main')
    scss = self.scss
    if self.children and self.children.length > 0
      self.children.each do |child|
        scss += "\n/* #{child.id} (#{child.name}) */\n"
        scss += child.deep_scss(view).to_s
      end
    end
    scss
  end

  def css(view = 'main', deep = true)
    begin
      scss = deep ? self.deep_scss(view) : self.scss(view)
      Sass::Engine.new(scss, syntax: :scss).render()
    rescue Exception => e
      if Rails.env.production?
        puts "Error compiling stylesheet for Widget ##{self.id} (#{self.name}): #{e}\n#{self.deep_scss}"
        ""
      else
        puts "Error compiling stylesheet for Widget ##{self.id} (#{self.name}): #{self.deep_scss}"
        raise e
      end
    end
  end

  def javascript(view = "main")
    template = self.template(view)
    unless template
      puts "No template '#{view}' for #{self.name}"
      return ""
    end
    # # wrap all javascript into self executing function
    # javascript = "(function(){"+ template['javascript'] +"})();" if template['javascript']
    javascript = ""
    javascript = template['javascript'] if template['javascript']
    javascript = Liquid::Template.parse(javascript).render(self.liquid_data) if javascript
    #recursivley append all children's javascript
    if self.children and self.children.length > 0
      self.children.each do |child|
        javascript +="\n#{child.javascript(view)}"
      end
    end
    javascript
  end

  def to_s
    self.html
  end

  def liquid_data
    named_children = children.inject({}) do |result, widget|
      result[widget.name.to_s] = widget
      result
    end
    data = named_children

    data.merge! self.deep_fields_hash

    data.merge!({
      'child'        => named_children,
      'all_children' => self.children,
      'visible_children' => self.visible_children,
      'fields'       => self.deep_fields_hash,
      'name'         => self.name,
      'id'           => self.id,
      'widget'       => self
    })

    data
  end

  def template(view, cached_widgets = nil)
    sooper = self.cached_super_widget(cached_widgets)
    template = self.templates.find { |templait| templait['view'] == view }
    template ||= sooper.template(view) if sooper
    template
  end

  def views(cached_widgets = nil)
    sooper = self.cached_super_widget(cached_widgets)
    views = self.templates.map { |templait| templait['view'] }
    views.push(*sooper.views(cached_widgets)) if sooper
    views.uniq
  end

  def get_deep_templates_hash(cached_widgets = nil)
    self.views(cached_widgets).inject({}) do |result, view|
      result[view] = self.template(view, cached_widgets)
      result
    end
  end

  def field(label, cached_widgets = nil)
    sooper = self.cached_super_widget(cached_widgets)
	# return nil if self.fields.nil?||self.fields.empty?
    field = self.fields.find { |feeld| feeld['label'] == label } if self.fields
    field ||= sooper.field(label) if sooper
		return field if field.nil?||field.empty?

    if ( field['type'] == 'media' ||
         field['type'] == "gallery" )
      self.profileable_attributes(field)
			return field
    elsif ( field['type'] == 'media_new' )
			out=field.clone
			id=field['value']
			out['value']={}
			out['value']['id']=id
      items=self.items_for_media_new(id)
      out['value']['items'] =items
    elsif ( field['type'] == 'gallery_new' )
			out=field.clone
			id=field['value']
			out['value']={}
			out['value']['id']=id
      items=self.items_for_gallery_new(id)
      out['value']['items'] =items
    elsif ( field['type'] == 'data' )
			query=field['value']
			self.data=query
    else
      out =field
    end
    out
  end
  def data
    deep_fields
  end
  def profileable_attributes(field)
    begin
      if field['type'] == "gallery"
        field['value']['items'] = self.items_for_gallery(field)
      elsif field['type'] == "gallery_new"
        field['value']['items'] = self.items_for_gallery_new(field)
      elsif field['value']
        item = MediaLibrary::Profile.find(field['value']['id'])
        field['value']['items'] = [ item.profileable_type.constantize.find(item.profileable_id).attributes ]
        if field['value']['items'].present? and field['value']['items'][0].present? and field['value']['items'][0]['alt_thumbnail_id'].present?
          field['value']['items'][0]['alt_thumbnail'] = alt_thumbnail(field['value']['items'][0]['alt_thumbnail_id'])
        end
        if item.profileable_type == "MediaLibrary::Document"
          field['value']['items'][0]['variations'] = variation_attributes(item.profileable_id)
        end
        if field['value']['gallery_ids'] && field['value']['gallery_ids'].length > 0
          field['value']['galleries'] = field['value']['gallery_ids'].inject([]) do |result, gallery_id|
            g = MediaLibrary::Gallery.where(id: gallery_id).first
            result << { 'title' => url_encode(g.title), 'id' => g.id }
            result
          end
        end
        field['value']['url_encoded_title'] = url_encode(field['value']['title'])
      else
        []
      end
    rescue ActiveRecord::RecordNotFound
      []
    end
  end
  
  def profileable_attributes_debug(field)
    begin
      if field['type'] == "gallery"
logger.debug "9999"
logger.debug "#{field.inspect}"
        items=self.items_for_gallery(field)
        field['value']['items'] = items
logger.debug "#{items.inspect}"
logger.debug "333"
        field['value']['items'] = self.items_for_gallery(field)
      elsif field['type'] == "gallery_new"
logger.debug "8888"
logger.debug "#{field.inspect}"
        gid=field['value']
        out=field.clone 
				out['value']={}
        items=self.items_for_gallery_new(gid)
logger.debug "#{items.inspect}"
logger.debug "222"
        out['value']['items'] = items
logger.debug "#{items.inspect}"
logger.debug "333"
      elsif field['type'] == "media_new"
        id=field['value']
        out=field.clone 
        out['value']={}
        out['value']['items'] = Medium.find(id) 
      elsif field['value']
logger.debug "0000"
        item = MediaLibrary::Profile.find(field['value']['id'])
        field['value']['items'] = [ item.profileable_type.constantize.find(item.profileable_id).attributes ]
        if field['value']['items'].present? and field['value']['items'][0].present? and field['value']['items'][0]['alt_thumbnail_id'].present?
          field['value']['items'][0]['alt_thumbnail'] = alt_thumbnail(field['value']['items'][0]['alt_thumbnail_id'])
        end
        if item.profileable_type == "MediaLibrary::Document"
          field['value']['items'][0]['variations'] = variation_attributes(item.profileable_id)
        end
        if field['value']['gallery_ids'] && field['value']['gallery_ids'].length > 0
          field['value']['galleries'] = field['value']['gallery_ids'].inject([]) do |result, gallery_id|
            g = MediaLibrary::Gallery.where(id: gallery_id).first
            result << { 'title' => url_encode(g.title), 'id' => g.id }
            result
          end
        end
        field['value']['url_encoded_title'] = url_encode(field['value']['title'])
      else
        []
      end
    rescue ActiveRecord::RecordNotFound
      []
    end
  end

  def alt_thumbnail(id)
    begin
      item = MediaLibrary::Profile.find(id)
      {
        original_url:  item.profileable.file.to_s,
        small_url:     item.profileable.file.small.url,
        thumbnail_url: item.profileable.file.thumbnail.url,
        medium_url:    item.profileable.file.medium.url,
        large_url:     item.profileable.file.large.url
      }
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  def items_for_gallery(field)
    begin

    items= []
    item_instances = []
		gid=field['value']['id']
      if gid.present?
        items = MediaLibrary::Profile.where("id in (?)", MediaLibrary::Gallery.find(gid).gallery_profiles.map(&:profile_id))#.order('updated_at DESC, id DESC')
logger.debug "aaaa"
logger.debug "#{items.inspect}"
logger.debug "bbbb"
        if items.length > 0
          items.each do |item|

            item_instances << {
              title: item.title,
              description: item.description,
              attributes: item.profileable_type.constantize.find(item.profileable_id).attributes,
              alt_thumbnail: (item.alt_thumbnail_id.present?) ? alt_thumbnail(item.alt_thumbnail_id) : nil,
              variations: (item.profileable_type == "MediaLibrary::Document") ? variation_attributes(item.profileable_id) : nil
            }
          end
        end
      end
      item_instances
    rescue ActiveRecord::RecordNotFound
        []
    end
  end
  def items_for_media_new(media_id)
    begin    
      item = Medium.find(media_id)
      item_instances=[]
      item_instances << {
        title: item.title,
        description: item.description,
        large_url:item.item.url(:large),
        medium_url:item.item.url(:medium),
        small_url:item.item.url(:small),
        original_url:item.item.url(:original_url),        
        attributes: item.attributes
      }
    rescue ActiveRecord::RecordNotFound
        []
    end    
  end
  def items_for_gallery_new(gallery_id)
    begin
    items, item_instances = [], []
      gid=gallery_id
      if gid
        gallery=List.find(gid)
        items =gallery.media.order('order_by')
        if items.length > 0
          items.each do |item|

            item_instances << {
              title: item.title,
              sub_title: item.sub_title,
              description: item.description,
              large_url:item.item.url(:large),
              medium_url:item.item.url(:medium),
              small_url:item.item.url(:small),
              original_url:item.item.url(:original_url),
              attributes: item.attributes,
              #attributes: item.profileable_type.constantize.find(item.profileable_id).attributes,
              #alt_thumbnail: (item.alt_thumbnail_id.present?) ? alt_thumbnail(item.alt_thumbnail_id) : nil,
              alt_thumbnail:nil
            }
          end
        end
      end
logger.debug "#{item_instances.inspect}"
      item_instances
    rescue ActiveRecord::RecordNotFound
        []
    end
  end

  def variation_attributes(id)
    begin
      MediaLibrary::Document.find(id).variations.map(&:attributes)
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  def value(label, cached_widgets = nil)
    field = self.field(label, cached_widgets)
    field['value'] if field
  end

  def cached_super_widget(cached_widgets = nil)
    if cached_widgets
      cached_widgets.find { |w| w.id == self.super_widget_id }
    else
      self.inheritance_parent
    end
  end

  def field_labels(cached_widgets = nil)
    sooper = self.cached_super_widget(cached_widgets)
    field_labels = self.fields.map { |field| field['label'] }
    field_labels = field_labels.push(*sooper.field_labels(cached_widgets)) if sooper
    field_labels.uniq
  end

  def get_deep_fields_hash(cached_widgets = nil)
    self.field_labels(cached_widgets).inject({}) do |result, label|
      result[label] = self.value(label, cached_widgets)
      result
    end
  end

  def get_deep_fields(cached_widgets = nil)
    self.field_labels(cached_widgets).map { |label| field(label, cached_widgets) }
  end

  def to_indexed_json
    {
        name: self.name,
        content: self.search_content,
        search_tags: self.search_content_tags
      }.to_json
  end

  def search_content
    self.field_labels.include?('body') ? self.fields.find{ |field| field['label'] == 'body' } : ''
  end

  def search_content_tags
    self.field_labels.include?('search_tag_list') ? self.value('search_tag_list') : ''
  end

  def deep_destroy(parental_relation = nil)
    self.progeny.each do |relation|
      relation.child.deep_destroy(relation)
    end

    if parents.count > 1 # don't delete because it has another parent
      parental_relation.destroy if parental_relation
    else
      self.destroy
    end
  end

  def set_hidden_to_false
    if self.field('body') && self.field('body')['options'] && self.field('body')['options']['hidden']
      self.field('body')['options']['hidden'] = 'false'
    end
  end
end
