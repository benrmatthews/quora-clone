# coding: utf-8
class HomeController < ApplicationController
  before_filter :require_user_text, :only => [:update_in_place,:mute_suggest_item]
  before_filter :require_user, :except => [:about,:index]

  def index
    @per_page = 20
    if current_user
      @notifies, @notifications = current_user.unread_notifies
      
      if current_user.following_ids.size == 0 and current_user.followed_ask_ids.size == 0 and current_user.followed_topic_ids.size == 0
        redirect_to newbie_path and return
      else
        # TODO: 这里需要过滤掉烂问题
        @logs = Log.any_of({:user_id.in => current_user.following_ids},
                           {:target_id.in => current_user.followed_ask_ids})
                          .and(:action.in => ["NEW", "AGREE", "EDIT"], :_type.in => ["AskLog", "AnswerLog", "CommentLog", "UserLog"])
                          .excludes(:user_id => current_user.id).desc("$natural")
                          .paginate(:page => params[:page], :per_page => @per_page)
        
        if @logs.count < 1
          @asks = Ask.normal.any_of({:topics.in => current_user.followed_topics.map{|t| t.name}}).not_in(:follower_ids => [current_user.id])
          @asks = @asks.includes(:user,:last_answer,:last_answer_user,:topics)
                        .exclude_ids(current_user.muted_ask_ids)
                        .desc(:answers_count,:answered_at)
                        .paginate(:page => params[:page], :per_page => @per_page)
                        
          if params[:format] == "js"
            render "/asks/index.js"
          end
        else
          if params[:format] == "js"
            render "/logs/index.js"
          else
            render "/logs/index"
          end
        end
      end
    else
      @asks = Ask.normal.recent.includes(:user,:last_answer,:last_answer_user,:topics)
                  .paginate(:page => params[:page], :per_page => @per_page)
      if params[:format] == "js"
        render "/asks/index.js"
      end
    end
  end
  
  def newbie
    @notifies, @notifications = current_user.unread_notifies
    ask_logs = Log.any_of({:_type => "AskLog"}, {:_type => "UserLog", :action.in => ["FOLLOW_ASK", "UNFOLLOW_ASK"]}).where(:created_at.gte => (Time.now - 12.hours))
    answer_logs = Log.any_of({:_type => "AnswerLog"}, {:_type => "UserLog", :action => "AGREE"}).where(:created_at.gte => (Time.now - 12.hours))
    @asks = Ask.normal.any_of({:_id.in => ask_logs.map {|l| l.target_id}.uniq}, {:_id.in => answer_logs.map {|l| l.target_parent_id}.uniq}).order_by(:answers_count.asc, :views_count.asc)
    h = {} 
    # 将回答次数*topic，以加入回答次数
    @hot_topics = @asks.inject([]) { |memo, ask|
      memo += ask.topics
    }
    @hot_topics.delete("Who also")
    @hot_topics.delete("Know almost")
    @hot_topics.delete("Feedback")
    @hot_topics.delete("zheye")
    @hot_topics.delete("Quora")
    @hot_topics.delete("quora")
    
    @hot_topics.each { |str| 
      h[str] = (h[str] || 0) + 1 
    }
    @hot_topics = h.sort{|a, b|b[1]<=>a[1]}.collect{|tmp|tmp[0]}[0..8]
  end
  
  def timeline
    @per_page = 20
    # @logs = Log.any_in(:user_id => curr)
  end
  
  def followed
    @per_page = 20
    @asks = current_user ? current_user.followed_asks.normal : Ask.normal
    @asks = @asks.includes(:user,:last_answer,:last_answer_user,:topics)
                  .exclude_ids(current_user.muted_ask_ids)
                  .desc(:answered_at,:id)
                  .paginate(:page => params[:page], :per_page => @per_page)

    if params[:format] == "js"
      render "/asks/index.js"
    else
      render "index"
    end
  end
  
  def recommended
    @per_page = 20
    @asks = current_user ? Ask.normal.any_of({:topics.in => current_user.followed_topics.map{|t| t.name}}).not_in(:follower_ids => [current_user.id]).and(:answers_count.lt => 1) : Ask.normal
    @asks = @asks.includes(:user,:last_answer,:last_answer_user,:topics)
                  .exclude_ids(current_user.muted_ask_ids)
                  .desc(:answers_count,:answered_at)
                  .paginate(:page => params[:page], :per_page => @per_page)

    if params[:format] == "js"
      render "/asks/recommended.js"
    end
  end

  # 查看用户不感兴趣的问题
  def muted
    @per_page = 20
    @asks = Ask.normal.includes(:user,:last_answer,:last_answer_user,:topics)
                  .only_ids(current_user.muted_ask_ids)
                  .desc(:answered_at,:id)
                  .paginate(:page => params[:page], :per_page => @per_page)

    set_seo_meta("I muted the question")

    if params[:format] == "js"
      render "/asks/index.js"
    else
      render "index"
    end
  end

  def update_in_place
    # TODO: Here need to chack permission
    klass, field, id = params[:id].split('__')
    puts params[:id]

    # 验证权限,用户是否有修改制定信息的权限
    case klass
    when "user" then return if current_user.id.to_s != id
    end
    
    params[:value] = simple_format(params[:value].to_s.strip) if params[:did_editor_content_formatted] == "no"

    object = klass.camelize.constantize.find(id)
    update_hash = {field => params[:value]}
    if ["ask","topic"].include?(klass) and current_user
      update_hash[:current_user_id] = current_user.id
    end
    if object.update_attributes(update_hash)
      render :text => object.send(field).to_s
    else
      Rails.logger.info "object.errors.full_messages: #{object.errors.full_messages}"
      render :text => object.errors.full_messages.join("\n"), :status => 422
    end
  end

  def about
    set_seo_meta("With respect to")
    @users = User.any_in(:email => Setting.admin_emails)
  end
  
  def mark_notifies_as_read
    if !params[:ids]
      render :text => "0"
    else
      notifications = current_user.notifications.any_in(:_id => params[:ids].split(","))
      notifications.each do |notify|
        # Rails.logger.info "mark_notifies_as_read\n"
        notify.update_attribute(:has_read, true)
      end
      render :text => "1"
    end
  end

  def report
    name = "Visitors"
    if current_user
      name = current_user.name
    end
    ReportSpam.add(params[:url],params[:desc],name)
    flash[:notice] = "Report information has been submitted，thank you."
    redirect_to params[:url]
  end

  def mute_suggest_item
    UserSuggestItem.mute(current_user.id, params[:type].strip.titleize, params[:id])
    render :text => "1"
  end

end
