class CreatePostsSolutionColumn < ActiveRecord::Migration[6.1]
  def change
    add_column :posts, :solution, :boolean, default: false, null: true
  end
end
