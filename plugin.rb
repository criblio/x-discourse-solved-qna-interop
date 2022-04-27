# frozen_string_literal: true

# name: x-discourse-solved-qna-interop
# about: Extend Discourse Solved & Question n Answer plugins and make them work together as specced.
# version: 0.0.3
# url: https://github.com/paviliondev/x-discourse-solved-qna-interop
# authors: merefield

register_asset "stylesheets/common/common.scss"

after_initialize do
  TopicList.preloaded_custom_fields << "accepted_answer_actioning_user_id" if TopicList.respond_to? :preloaded_custom_fields

  class ::Guardian

    def can_accept_answer?(topic, post)
      
      return false if !authenticated?
      return false if !topic || !post || post.whisper?
      return false if !allow_accepted_answers?(topic.category_id, topic.tags.map(&:name))

      accepted_id = topic.custom_fields["accepted_answer_post_id"].to_i
      actioning_user_id = topic.custom_fields["accepted_answer_actioning_user_id"].to_i

      if accepted_id > 0 && !actioning_user_id.nil?
        actioning_user = User.find_by(id: actioning_user_id)
        return false if actioning_user && actioning_user.admin? && !is_staff? 
      end

      return true if is_staff?
      return true if current_user.trust_level >= SiteSetting.accept_all_solutions_trust_level

      if respond_to? :can_perform_action_available_to_group_moderators?
        return true if can_perform_action_available_to_group_moderators?(topic)
      end

      topic.user_id == current_user.id && !topic.closed && SiteSetting.accept_solutions_topic_author
    end
  end

  module ::DiscourseSolved

    def self.accept_answer!(post, acting_user, topic: nil)
      topic ||= post.topic

      DistributedMutex.synchronize("discourse_solved_toggle_answer_#{topic.id}") do
        accepted_id = topic.custom_fields["accepted_answer_post_id"].to_i

        if accepted_id > 0
          if p2 = Post.find_by(id: accepted_id)
            p2.custom_fields.delete("is_accepted_answer")
            p2.solution = false
            p2.save!

            if defined?(UserAction::SOLVED)
              UserAction.where(
                action_type: UserAction::SOLVED,
                target_post_id: p2.id
              ).destroy_all
            end
          end
        end

        post.solution = true
        post.solution_actor_user_id = acting_user.id
        post.custom_fields["is_accepted_answer"] = "true"
        topic.custom_fields["accepted_answer_post_id"] = post.id
        topic.custom_fields["accepted_answer_actioning_user_id"] = acting_user.id

        if defined?(UserAction::SOLVED)
          UserAction.log_action!(
            action_type: UserAction::SOLVED,
            user_id: post.user_id,
            acting_user_id: acting_user.id,
            target_post_id: post.id,
            target_topic_id: post.topic_id
          )
        end

        notification_data = {
          message: 'solved.accepted_notification',
          display_username: acting_user.username,
          topic_title: topic.title
        }.to_json

        unless acting_user.id == post.user_id
          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: post.user_id,
            topic_id: post.topic_id,
            post_number: post.post_number,
            data: notification_data
          )
        end

        if SiteSetting.notify_on_staff_accept_solved && acting_user.id != topic.user_id
          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: topic.user_id,
            topic_id: post.topic_id,
            post_number: post.post_number,
            data: notification_data
          )
        end

        auto_close_hours = SiteSetting.solved_topics_auto_close_hours

        if (auto_close_hours > 0) && !topic.closed
          topic_timer = topic.set_or_create_timer(
            TopicTimer.types[:silent_close],
            nil,
            based_on_last_post: true,
            duration_minutes: auto_close_hours * 60
          )

          topic.custom_fields[
            AUTO_CLOSE_TOPIC_TIMER_CUSTOM_FIELD
          ] = topic_timer.id

          MessageBus.publish("/topic/#{topic.id}", reload_topic: true)
        end

        topic.save!
        post.save!

        if WebHook.active_web_hooks(:solved).exists?
          payload = WebHook.generate_payload(:post, post)
          WebHook.enqueue_solved_hooks(:accepted_solution, post, payload)
        end

        DiscourseEvent.trigger(:accepted_solution, post)
      end
    end

    def self.unaccept_answer!(post, topic: nil)
      topic ||= post.topic

      DistributedMutex.synchronize("discourse_solved_toggle_answer_#{topic.id}") do
        post.custom_fields.delete("is_accepted_answer")
        topic.custom_fields.delete("accepted_answer_post_id")

        if timer_id = topic.custom_fields[AUTO_CLOSE_TOPIC_TIMER_CUSTOM_FIELD]
          topic_timer = TopicTimer.find_by(id: timer_id)
          topic_timer.destroy! if topic_timer
          topic.custom_fields.delete(AUTO_CLOSE_TOPIC_TIMER_CUSTOM_FIELD)
        end

        post.solution = false
        post.solution_actor_user_id = nil
        topic.save!
        post.save!

        # TODO remove_action! does not allow for this type of interface
        if defined? UserAction::SOLVED
          UserAction.where(
            action_type: UserAction::SOLVED,
            target_post_id: post.id
          ).destroy_all
        end

        # yank notification
        notification = Notification.find_by(
          notification_type: Notification.types[:custom],
          user_id: post.user_id,
          topic_id: post.topic_id,
          post_number: post.post_number
        )

        notification.destroy! if notification

        if WebHook.active_web_hooks(:solved).exists?
          payload = WebHook.generate_payload(:post, post)
          WebHook.enqueue_solved_hooks(:unaccepted_solution, post, payload)
        end

        DiscourseEvent.trigger(:unaccepted_solution, post)
      end
    end
  end

  module QuestionAnswer
    module PostSerializerExtension
      def self.included(base)
        base.attributes(
          :qa_vote_count,
          :solution,
          :solution_actor_user_id,
          :qa_user_voted_direction,
          :qa_has_votes,
          :comments,
          :comments_count,
        )
      end
  
      def solution
       object.solution
      end

      def solution_actor_user_id
        object.solution_actor_user_id
      end
    end
  end

  TopicView.apply_custom_default_scope do |scope, topic_view|
    if topic_view.topic.is_qa? &&
      !topic_view.instance_variable_get(:@replies_to_post_number) &&
      !topic_view.instance_variable_get(:@post_ids)

      scope = scope.where(
        reply_to_post_number: nil,
        post_type: Post.types[:regular]
      )

      scope = scope
        .unscope(:order)
        .order("CASE post_number WHEN 1 THEN 0 ELSE 1 END, solution DESC, qa_vote_count DESC, post_number ASC")
      scope
    else
      scope
    end
  end

  class ::PostSerializer
    include QuestionAnswer::PostSerializerExtension
  end

  class WebHookPostSerializer < PostSerializer
  end
end
