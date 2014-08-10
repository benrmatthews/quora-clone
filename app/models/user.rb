# coding: utf-8
class User
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Voter
  include BaseModel
  
  devise :invitable, :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  
  field :name
  field :slug
  field :tagline
  field :bio
  field :avatar
  field :website
  # 是否是女人
  field :girl, :type => Boolean, :default => false
  # 软删除标记，1 表示已经删除
  field :deleted, :type => Integer
  # 是否是可信用户，可信用户有更多修改权限
  field :credible, :type => Boolean, :default => false

  # 不感兴趣的问题
  field :muted_ask_ids, :type => Array, :default => []
  # 关注的问题
  field :followed_ask_ids, :type => Array, :default => []
  # 回答过的问题
  field :answered_ask_ids, :type => Array, :default => []
  # Email 提醒的状态
  field :mail_be_followed, :type => Boolean, :default => true
  field :mail_new_answer, :type => Boolean, :default => true
  field :mail_invite_to_ask, :type => Boolean, :default => true
  field :mail_ask_me, :type => Boolean, :default => true
  field :thanked_answer_ids, :type => Array, :default => []

  # 邀请字段
  field :invitation_token
  field :invitation_sent_at, :type => DateTime

  field :asks_count, :type => Integer, :default => 0
  has_many :asks

  field :answers_count, :type => Integer, :default => 0
  has_many :answers
  has_many :notifications
  has_many :inboxes

  index :slug, :uniq => true
  index :email, :uniq => true
  index :follower_ids
  index :following_ids
  index :followed_ask_ids
  index :followed_topic_ids

  references_and_referenced_in_many :followed_asks, :stored_as => :array, :inverse_of => :followers, :class_name => "Ask"
  references_and_referenced_in_many :followed_topics, :stored_as => :array, :inverse_of => :followers, :class_name => "Topic"
  
  references_and_referenced_in_many :following, :class_name => 'User', :inverse_of => :followers, :index => true, :stored_as => :array
  references_and_referenced_in_many :followers, :class_name => 'User', :inverse_of => :following, :index => true, :stored_as => :array

  embeds_many :authorizations
  has_many :logs, :class_name => "Log", :foreign_key => "target_id"

  attr_accessor  :password_confirmation
  attr_accessible :email, :password,:name, :slug, :tagline, :bio, :avatar, :website, :girl, 
                  :mail_new_answer, :mail_be_followed, :mail_invite_to_ask, :mail_ask_me,
                  :credible

  validates_presence_of :name, :slug
  validates_uniqueness_of :slug
  validates_format_of :slug, :with => /[a-z0-9\-\_]{3,20}/i

  # 以下两个方法是给 redis search index 用
  def avatar_small
    self.avatar.small.url
  end
  def avatar_small_changed?
    self.avatar_changed?
  end

  # 用户评分，暂时方案
  def score
    self.answers_count + self.follower_ids.count * 2
  end
  def score_changed?
    self.answers_count_changed?
  end
  

  # 敏感词验证
  before_validation :check_spam_words
  def check_spam_words
    if self.spam?("tagline")
      return false
    end
    if self.spam?("name")
      return false
    end
    if self.spam?("slug")
      return false
    end
    if self.spam?("bio")
      return false
    end
  end

  before_save :downcase_email
  def self.find_for_authentication(conditions) 
    conditions[:email].try(:downcase!)
    super
  end

  def self.find_or_initialize_with_errors(required_attributes, attributes, error=:invalid)
    attributes[:email].try(:downcase!)
    super
  end

  def downcase_email
    self.email.downcase!
  end

  def password_required?
    !persisted? || password.present? || password_confirmation.present?
  end
  
  mount_uploader :avatar, AvatarUploader

  def self.create_from_hash(auth)  
		user = User.new
		user.name = auth["user_info"]["name"]  
		user.email = auth['user_info']['email']
    if user.email.blank?
      user.errors.add("Email","三方网站没有提供你的Email信息，无法直接注册。")
      return user
    end
		user.save
		user
  end  

  before_validation :auto_slug
  # 此方法用于处理开始注册是自动生成 slug, 因为没表单,只能自动
  def auto_slug
    if self.slug.blank?
      if !self.email.blank?
        self.slug = self.email.split("@")[0]
        self.slug = self.slug.safe_slug
      end
      # 如果 slug 被 safe_slug 后是空的,就用 id 代替
      if self.slug.blank?
        self.slug = self.id.to_s
      end
    else
      self.slug = self.slug.safe_slug
    end

    # 防止重复 slug
    old_user = User.find_by_slug(self.slug)
    if !old_user.blank? and old_user.id != self.id
      self.slug = self.id.to_s
    end
  end

  def auths
    self.authorizations.collect { |a| a.provider }
  end

  def self.find_by_slug(slug)
    first(:conditions => {:slug => slug})
  end

  # 不感兴趣问题
  def ask_muted?(ask_id)
    self.muted_ask_ids.include?(ask_id)
  end
  
  def ask_followed?(ask)
    self.followed_ask_ids.include?(ask.id)
  end
  
  def followed?(user)
    self.following_ids.include?(user.id)
  end
  
  def topic_followed?(topic)
    self.followed_topic_ids.include?(topic.id)
  end
  
  def mute_ask(ask_id)
    self.muted_ask_ids ||= []
    return if self.muted_ask_ids.index(ask_id)
    self.muted_ask_ids << ask_id
    self.save
  end
  
  def unmute_ask(ask_id)
    self.muted_ask_ids.delete(ask_id)
    self.save
  end
  
  def follow_ask(ask)
    ask.followers << self
    ask.save
    
    insert_follow_log("FOLLOW_ASK", ask)
  end
  
  def unfollow_ask(ask)
    self.followed_asks.delete(ask)
    self.save
    
    ask.followers.delete(self)
    ask.save
    
    insert_follow_log("UNFOLLOW_ASK", ask)
  end
  
  def follow_topic(topic)
    return if topic.follower_ids.include? self.id
    topic.followers << self
    topic.followers_count_changed = true
    topic.save

    # 清除推荐话题
    UserSuggestItem.delete(self.id, "Topic", topic.id)
    
    insert_follow_log("FOLLOW_TOPIC", topic)
  end
  
  def unfollow_topic(topic)
    self.followed_topics.delete(topic)
    self.save
    
    topic.followers.delete(self)
    topic.followers_count_changed = true
    topic.save
    
    insert_follow_log("UNFOLLOW_TOPIC", topic)
  end
  
  def follow(user)
    user.followers << self
    user.save

    # 清除推荐话题
    UserSuggestItem.delete(self.id, "User", user.id)

    # 发送被 Follow 的邮件
    UserMailer.be_followed(user.id,self.id).deliver
    
    insert_follow_log("FOLLOW_USER", user)
  end
  
  def unfollow(user)
    self.following.delete(user)
    self.save
    
    user.followers.delete(self)
    user.save
    
    insert_follow_log("UNFOLLOW_USER", user)
  end

  # 感谢回答
  def thank_answer(answer)
    self.thanked_answer_ids ||= []
    return true if self.thanked_answer_ids.index(answer.id)
    self.thanked_answer_ids << answer.id
    self.save

    insert_follow_log("THANK_ANSWER", answer, answer.ask)
  end

  # 软删除
  # 只是把用户信息修改了
  def soft_delete
    # assuming you have deleted_at column added already
    return false if self.deleted == 1
    self.deleted = 1
    self.name = "#{self.name}[已注销]"
    self.email = "#{self.id}@zheye.org"
    self.slug = "#{self.id}"
    self.save
  end
  
  # 我的通知
  def unread_notifies
    notifies = {}
    notifications = self.notifications.unread.includes(:log)
    notifications.each do |notify|
      notifies[notify.target_id] ||= {}
      notifies[notify.target_id][:items] ||= []
      
      case notify.action
      when "FOLLOW" then notifies[notify.target_id][:type] = "USER"
      when "THANK_ANSWER" then notifies[notify.target_id][:type] = "THANK_ANSWER"
      when "INVITE_TO_ANSWER" then notifies[notify.target_id][:type] = "INVITE_TO_ANSWER"
      when "NEW_TO_USER" then notifies[notify.target_id][:type] = "ASK_USER"
      else  
        notifies[notify.target_id][:type] = "ASK"
      end
      notifies[notify.target_id][:items] << notify
    end
    
    [notifies, notifications]
  end

  # 推荐给我的人或者话题
  def suggest_items
    return UserSuggestItem.gets(self.id, :limit => 6)
  end
  
  # 刷新推荐的人
  def refresh_suggest_items
    related_people = self.followed_topics.inject([]) do |memo, topic|
      memo += topic.followers
    end.uniq
    related_people = related_people - self.following - [self] if related_people
    
    related_topics = self.following.inject([]) do |memo, person|
      memo += person.followed_topics
    end.uniq
    related_topics -= self.followed_topics if related_topics
    
    items = related_people + related_topics
    # 存入 Redis
    saved_count = 0
    # 先删除就的缓存
    UserSuggestItem.delete_all(self.id)
    mutes = UserSuggestItem.get_mutes(self.id)
    items.shuffle.each do |item|
      klass = item.class.to_s
      # 跳过 mute 的信息
      next if mutes.include?({"type" => klass, "id" => item.id.to_s})
      # 跳过删除的用户
      next if klass == "User" and item.deleted == 1
      usi = UserSuggestItem.new(:user_id => self.id, 
                                :type => klass,
                                :id => item.id)
      if usi.save
        saved_count += 1
      end
    end
    saved_count
  end

  protected
  
    def insert_follow_log(action, item, parent_item = nil)
      begin
        log = UserLog.new
        log.user_id = self.id
        log.title = self.name
        log.target_id = item.id
        log.action = action
        if parent_item.blank?
          log.target_parent_id = item.id
          log.target_parent_title = item.is_a?(Ask) ? item.title : item.name
        else
          log.target_parent_id = parent_item.id
          log.target_parent_title = parent_item.title
        end
        log.diff = ""
        log.save
      rescue Exception => e
        
      end
    end

end
