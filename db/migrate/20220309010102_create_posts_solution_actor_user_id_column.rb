class CreatePostsSolutionActorUserIdColumn < ActiveRecord::Migration[6.1]
  def change
    add_column :posts, :solution_actor_user_id, :integer, null: true
  end
end
