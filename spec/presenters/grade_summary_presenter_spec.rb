# frozen_string_literal: true

#
# Copyright (C) 2013 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

describe GradeSummaryPresenter do
  describe "#courses_with_grades" do
    describe "all on one shard" do
      let(:course) { Course.create! }
      let(:presenter) { GradeSummaryPresenter.new(course, @user, nil) }
      let(:assignment) { assignment_model(course:) }
      let(:enrollment) { course.enroll_student(@user, enrollment_state: "active") }

      before do
        user_factory
        enrollment
        course.offer
      end

      it "preloads the enrollment term for each course" do
        enrollment_terms = presenter.courses_with_grades.map { |c| c.association(:enrollment_term) }

        expect(enrollment_terms).to all be_loaded
      end

      it "preloads the legacy grading period groups for each course" do
        grading_period_groups = presenter.courses_with_grades.map { |c| c.association(:grading_period_groups) }

        expect(grading_period_groups).to all be_loaded
      end

      it "includes courses where the user is enrolled" do
        expect(presenter.courses_with_grades).to include(course)
      end

      it "includes concluded courses" do
        course.soft_conclude!
        course.save
        expect(presenter.courses_with_grades).to include(course)
      end

      it "includes courses for concluded enrollments" do
        enrollment.conclude
        expect(presenter.courses_with_grades).to include(course)
      end

      it "excludes soft-concluded courses where students are restricted after conclusion" do
        course.soft_conclude!
        course.settings = course.settings.merge(restrict_student_past_view: true)
        course.save!

        expect(presenter.courses_with_grades).not_to include(course)
      end
    end

    describe "across shards" do
      specs_require_sharding

      it "can find courses when the user and course are on the same shard" do
        user = course = enrollment = nil
        @shard1.activate do
          user = User.create!
          account = Account.create!
          course = account.courses.create!
          enrollment = StudentEnrollment.create!(course:, user:)
          enrollment.update_attribute(:workflow_state, "active")
          course.update_attribute(:workflow_state, "available")
        end

        presenter = GradeSummaryPresenter.new(course, user, user.id)
        expect(presenter.courses_with_grades).to include(course)
      end

      it "can find courses when the user and course are on different shards" do
        user = course = nil
        @shard1.activate do
          user = User.create!
        end

        @shard2.activate do
          account = Account.create!
          course = account.courses.create!
          enrollment = StudentEnrollment.create!(course:, user:)
          enrollment.update_attribute(:workflow_state, "active")
          course.update_attribute(:workflow_state, "available")
        end

        presenter = GradeSummaryPresenter.new(course, user, user.id)
        expect(presenter.courses_with_grades).to include(course)
      end

      describe "courses for an observer across shards" do
        before do
          course_with_student(active_all: true)
          @observer = user_factory(active_all: true)
          @course.observer_enrollments.create!(user_id: @observer, associated_user_id: @student)

          @shard1.activate do
            account = Account.create!
            @course2 = account.courses.create!(workflow_state: "available")
            StudentEnrollment.create!(course: @course2, user: @student, workflow_state: "active")
            @course2.observer_enrollments.create!(user_id: @observer, associated_user_id: @student)
          end

          @presenter = GradeSummaryPresenter.new(@course, @observer, @student.id)
        end

        it "can find courses for an observer across shards" do
          expect(@presenter.courses_with_grades).to match_array([@course, @course2])
        end

        it "preloads the enrollment term for each course" do
          enrollment_terms = @presenter.courses_with_grades.map { |c| c.association(:enrollment_term) }

          expect(enrollment_terms).to all be_loaded
        end

        it "preloads the legacy grading period groups for each course" do
          grading_period_groups = @presenter.courses_with_grades.map { |c| c.association(:grading_period_groups) }

          expect(grading_period_groups).to all be_loaded
        end
      end
    end
  end

  describe "#students" do
    before(:once) do
      @course = Course.create!
      @student = User.create!
      @teacher = User.create!
      @course.enroll_teacher(@teacher, active_all: true)
      @student_enrollment1 = @course.enroll_student(@student, active_all: true)
    end

    it "returns all of the observed students, if there are multiple" do
      student_two = User.create!
      @observer = User.create!
      @course.enroll_student(student_two, active_all: true)
      @course.observer_enrollments.create!(user_id: @observer, associated_user_id: @student)
      @course.observer_enrollments.create!(user_id: @observer, associated_user_id: student_two)

      presenter = GradeSummaryPresenter.new(@course, @observer, @student.id)
      expect(presenter.students.map(&:id)).to match_array [@student.id, student_two.id]
    end

    it "returns the observed student that has the enrollment manually concluded" do
      @observer = User.create!
      @observer_enrollment1 = @course.observer_enrollments.create!(user_id: @observer, associated_user_id: @student)

      @student_enrollment1.update_attribute(:workflow_state, "completed")
      @observer_enrollment1.update_attribute(:workflow_state, "completed")
      presenter = GradeSummaryPresenter.new(@course, @observer, @student.id)
      expect(presenter.students.map(&:id)).to match_array [@student.id]
    end

    it "returns an array with a single student if there is only one student" do
      presenter = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(presenter.students.map(&:id)).to match_array [@student.id]
    end

    it "returns an empty array if there are no students" do
      presenter = GradeSummaryPresenter.new(@course, @teacher, nil)
      expect(presenter.students).to be_empty
    end
  end

  describe "#assignment_stats" do
    before do
      teacher_in_course
    end

    it "works" do
      s1, s2, s3, s4 = n_students_in_course(4)
      a = @course.assignments.create! points_possible: 10
      a.grade_student s1, grade:  0, grader: @teacher
      a.grade_student s2, grade:  5, grader: @teacher
      a.grade_student s3, grade: 10, grader: @teacher

      # this student should be ignored
      a.grade_student s4, grade: 99, grader: @teacher
      s4.enrollments.each(&:destroy)

      ScoreStatisticsGenerator.update_score_statistics(@course.id)

      p = GradeSummaryPresenter.new(@course, @teacher, nil)
      stats = p.assignment_stats
      assignment_stats = stats[a.id]
      expect(assignment_stats.maximum.to_f).to eq 10
      expect(assignment_stats.minimum.to_f).to eq 0
      expect(assignment_stats.mean.to_f).to eq 5
      expect(assignment_stats.median.to_f).to eq 5
      expect(assignment_stats.lower_q.to_f).to eq 2.5
      expect(assignment_stats.upper_q.to_f).to eq 7.5
    end

    it "filters out test students and inactive enrollments" do
      s1, s2, s3, removed_student = n_students_in_course(4, course: @course)

      fake_student = course_with_user("StudentViewEnrollment", { course: @course }).user
      fake_student.preferences[:fake_student] = true

      a = @course.assignments.create! points_possible: 10
      a.grade_student s1, grade:  0, grader: @teacher
      a.grade_student s2, grade:  5, grader: @teacher
      a.grade_student s3, grade: 10, grader: @teacher
      a.grade_student removed_student, grade: 20, grader: @teacher
      a.grade_student fake_student, grade: 100, grader: @teacher

      removed_student.enrollments.each do |enrollment|
        enrollment.workflow_state = "inactive"
        enrollment.save!
      end

      ScoreStatisticsGenerator.update_score_statistics(@course.id)

      p = GradeSummaryPresenter.new(@course, @teacher, nil)
      stats = p.assignment_stats
      assignment_stats = stats[a.id]
      expect(assignment_stats.maximum.to_f).to eq 10
      expect(assignment_stats.minimum.to_f).to eq 0
      expect(assignment_stats.mean.to_f).to eq 5
    end

    it "doesnt factor nil grades into the average or min" do
      s1, s2, s3, s4 = n_students_in_course(4)
      a = @course.assignments.create! points_possible: 10
      a.grade_student s1, grade:  2, grader: @teacher
      a.grade_student s2, grade:  6, grader: @teacher
      a.grade_student s3, grade: 10, grader: @teacher
      a.grade_student s4, grade: nil, grader: @teacher

      ScoreStatisticsGenerator.update_score_statistics(@course.id)

      p = GradeSummaryPresenter.new(@course, @teacher, nil)
      stats = p.assignment_stats
      assignment_stats = stats[a.id]
      expect(assignment_stats.maximum.to_f).to eq 10
      expect(assignment_stats.minimum.to_f).to eq 2
      expect(assignment_stats.mean.to_f).to eq 6
    end

    it "returns a count of submissions ignoring test students and inactive enrollments" do
      @course = Course.create!
      teacher_in_course
      s1, s2, s3, removed_student = n_students_in_course(4, course: @course)

      fake_student = course_with_user("StudentViewEnrollment", { course: @course }).user
      fake_student.preferences[:fake_student] = true

      a = @course.assignments.create! points_possible: 10
      a.grade_student s1, grade:  0, grader: @teacher
      a.grade_student s2, grade:  5, grader: @teacher
      a.grade_student s3, grade: 10, grader: @teacher
      a.grade_student removed_student, grade: 20, grader: @teacher
      a.grade_student fake_student, grade: 100, grader: @teacher

      removed_student.enrollments.each do |enrollment|
        enrollment.workflow_state = "inactive"
        enrollment.save!
      end

      ScoreStatisticsGenerator.update_score_statistics(@course.id)

      p = GradeSummaryPresenter.new(@course, @teacher, nil)
      expect(p.assignment_stats.values.first.count).to eq 3
    end
  end

  describe "#observed_students" do
    before(:once) do
      @course = course_factory(active_all: true)
      @course.restrict_student_future_view = true
      @course.save!
      @student = user_factory
      @student2 = user_factory
      observer = user_with_pseudonym(active_all: true)
      section = @course.course_sections.create!
      section.start_at = 1.day.from_now
      section.restrict_enrollments_to_section_dates = true
      section.save!

      add_linked_observer(@student, observer)
      add_linked_observer(@student2, observer)
      @student_enrollment = section.enroll_user(@student, "StudentEnrollment")
      @student_enrollment2 = @course.enroll_user(@student2, "StudentEnrollment")

      @presenter = GradeSummaryPresenter.new(@course, observer, nil)
    end

    it "does not include students from future sections in a date restricted course" do
      expect(@presenter.observed_students).not_to have_key(@student)
    end

    it "includes students from current sections in a date restricted course" do
      expect(@presenter.observed_students).to include(@student2 => [@student_enrollment2])
    end

    it "includes all students if course is not restricted by date" do
      @course.restrict_student_future_view = false
      @course.save!
      expect(@presenter.observed_students).to include(@student => [@student_enrollment])
      expect(@presenter.observed_students).to include(@student2 => [@student_enrollment2])
    end
  end

  describe "#submissions" do
    before(:once) do
      teacher_in_course
      student_in_course
    end

    it "doesn't return submissions for deleted assignments" do
      a1, a2 = Array.new(2) do
        @course.assignments.create! points_possible: 10
      end
      a1.grade_student @student, grade: 10, grader: @teacher
      a2.grade_student @student, grade: 10, grader: @teacher

      a2.destroy

      p = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(p.submissions.map(&:assignment_id)).to eq [a1.id]
    end

    it "doesn't error on submissions for assignments not in the pre-loaded assignment list" do
      assign = @course.assignments.create! points_possible: 10
      assign.grade_student @student, grade: 10, grader: @teacher
      assign.update_attribute(:submission_types, "not_graded")

      p = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(p.submissions.map(&:assignment_id)).to eq [assign.id]
    end

    it "doesn't error on enable feature flag visibility_feedback_student_grades_page" do
      Account.site_admin.enable_feature!(:visibility_feedback_student_grades_page)
      assignment = @course.assignments.create!(points_possible: 10)
      submission_to_comment = assignment.grade_student(@student, grade: 10, grader: @teacher).first
      comment_1 = submission_to_comment.add_comment(comment: "a student comment", author: @teacher)
      comment_1.mark_read!(@student)
      submission_to_comment.add_comment(comment: "another comment", author: @teacher)
      p = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      submission = p.submissions.find { |s| s[:assignment_id] == assignment.id }
      expect(submission.submission_comments.length).to eq 2
      expect(submission.submission_comments[0].read?(@student)).to be true
      expect(submission.submission_comments[1].read?(@student)).to be false
    end
  end

  describe "#assignments" do
    before(:once) do
      teacher_in_course
      student_in_course
    end

    let!(:published_assignment) { @course.assignments.create! }

    it "filters unpublished assignments" do
      unpublished_assignment = @course.assignments.create!
      unpublished_assignment.update_attribute(:workflow_state, "unpublished")

      p = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(p.assignments).to eq [published_assignment]
    end

    it "filters wiki_page assignments" do
      wiki_page_assignment_model course: @course

      p = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(p.assignments).to eq [published_assignment]
    end

    it "includes assignments for deactivated students when a teacher is viewing" do
      @course.enrollments.find_by(user: @student).deactivate
      presenter = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(presenter.assignments).to include published_assignment
    end

    it "filters out hidden zero point quizzes when hide_zero_point_quizzes_option FF is enabled" do
      Account.site_admin.enable_feature!(:hide_zero_point_quizzes_option)
      @practice_quiz = @course.assignments.create!(name: "Practice Quiz", points_possible: 0, submission_types: ["external_tool"], omit_from_final_grade: true, hide_in_gradebook: true)
      presenter = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(presenter.assignments).not_to include @practice_quiz
    end

    it "does not filter out hidden zero point quizzes when hide_zero_point_quizzes_option FF is disabled" do
      Account.site_admin.disable_feature!(:hide_zero_point_quizzes_option)
      @practice_quiz = @course.assignments.create!(name: "Practice Quiz", points_possible: 0, submission_types: ["external_tool"], omit_from_final_grade: true, hide_in_gradebook: true)
      presenter = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(presenter.assignments).to include @practice_quiz
    end
  end

  describe "#sort_options" do
    before(:once) do
      teacher_in_course
      student_in_course
    end

    let(:presenter) { GradeSummaryPresenter.new(@course, @teacher, @student.id) }
    let(:assignment_group_option) { ["Assignment Group", "assignment_group"] }
    let(:module_option) { ["Module", "module"] }

    it "returns the default sort options" do
      default_options = [["Due Date", "due_at"], ["Name", "title"]]
      expect(presenter.sort_options).to include(*default_options)
    end

    it "does not return 'Assignment Group' as an option if the course has no assignments" do
      expect(presenter.sort_options).to_not include assignment_group_option
    end

    it "does not return 'Assignment Group' as an option if all of the " \
       "assignments belong to the same assignment group" do
      @course.assignments.create!(title: "Math Assignment")
      @course.assignments.create!(title: "Science Assignment")
      expect(presenter.sort_options).to_not include assignment_group_option
    end

    it "returns 'Assignment Group' as an option if there are " \
       "assignments that belong to different assignment groups" do
      @course.assignments.create!(title: "Math Assignment")
      science_group = @course.assignment_groups.create!(name: "Science Assignments")
      @course.assignments.create!(title: "Science Assignment", assignment_group: science_group)
      expect(presenter.sort_options).to include assignment_group_option
    end

    it "does not return 'Module' as an option if the course does not have any modules" do
      expect(presenter.sort_options).to_not include module_option
    end

    it "returns 'Module' as an option if the course has any modules" do
      @course.context_modules.create!(name: "I <3 Modules")
      expect(presenter.sort_options).to include module_option
    end

    it "localizes menu text" do
      @course.assignments.create!(title: "Math Assignment")
      science_group = @course.assignment_groups.create!(name: "Science Assignments")
      @course.assignments.create!(title: "Science Assignment", assignment_group: science_group)
      @course.context_modules.create!(name: "I <3 Modules")

      expect(I18n).to receive(:t).with("Due Date")
      expect(I18n).to receive(:t).with("Name")
      expect(I18n).to receive(:t).with("Assignment Group")
      expect(I18n).to receive(:t).with("Module")
      allow(I18n).to receive(:t).with(any_args)

      presenter.sort_options
    end

    it "sorts menu items in a locale-aware way" do
      expect(Canvas::ICU).to receive(:collate_by).with([["Due Date", "due_at"], ["Name", "title"]], &:first)
      presenter.sort_options
    end
  end

  describe "#sorted_assignments" do
    before(:once) do
      teacher_in_course
      student_in_course
    end

    let!(:assignment1) { @course.assignments.create!(title: "Jalapeno", due_at: 2.days.ago, position: 1) }
    let!(:assignment2) { @course.assignments.create!(title: "Jalapeño", due_at: 2.days.from_now, position: 2) }
    let!(:assignment3) { @course.assignments.create!(title: "Jalapezo", due_at: 5.days.ago, position: 3) }
    let(:ordered_assignment_ids) { presenter.assignments.map(&:id) }

    it "assignment order defaults to due_at" do
      presenter = GradeSummaryPresenter.new(@course, @teacher, @student.id)
      expect(presenter.assignment_order).to eq(:due_at)
    end

    context "assignment order: due_at" do
      let(:presenter) { GradeSummaryPresenter.new(@course, @teacher, @student.id, assignment_order: :due_at) }

      it "sorts by due_at" do
        expected_id_order = [assignment3.id, assignment1.id, assignment2.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end

      it "sorts assignments without due_ats after assignments with due_ats" do
        assignment1.due_at = nil
        assignment1.save!
        expected_id_order = [assignment3.id, assignment2.id, assignment1.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end

      it "sorts by assignment title if due_ats are equal" do
        assignment1.due_at = assignment3.due_at
        assignment1.save!
        expected_id_order = [assignment1.id, assignment3.id, assignment2.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end

      it "ignores case when comparing assignment titles" do
        assignment1.due_at = assignment3.due_at
        assignment1.title = "apple"
        assignment1.save!
        expected_id_order = [assignment1.id, assignment3.id, assignment2.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end
    end

    context "assignment order: title" do
      let(:presenter) { GradeSummaryPresenter.new(@course, @teacher, @student.id, assignment_order: :title) }

      it "sorts by title" do
        expected_id_order = [assignment1.id, assignment2.id, assignment3.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end

      it "ignores case when sorting by title" do
        assignment1.title = "apple"
        assignment1.save!
        expected_id_order = [assignment1.id, assignment2.id, assignment3.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end
    end

    context "assignment order: module" do
      let(:presenter) { GradeSummaryPresenter.new(@course, @teacher, @student.id, assignment_order: :module) }
      let!(:first_context_module) { @course.context_modules.create! }
      let!(:second_context_module) { @course.context_modules.create! }

      context "assignments not in modules" do
        it "sorts alphabetically for assignments not belonging to modules (ignoring case)" do
          assignment3.title = "apricot"
          assignment3.save!
          expected_id_order = [assignment3.id, assignment1.id, assignment2.id]
          expect(ordered_assignment_ids).to eq(expected_id_order)
        end
      end

      context "assignments in modules" do
        let!(:assignment1_tag) do
          a1_tag = assignment1.context_module_tags.new(context: @course, position: 1, tag_type: "context_module")
          a1_tag.context_module = second_context_module
          a1_tag.save!
        end

        let!(:assignment2_tag) do
          a2_tag = assignment2.context_module_tags.new(context: @course, position: 3, tag_type: "context_module")
          a2_tag.context_module = first_context_module
          a2_tag.save!
        end

        let!(:assignment3_tag) do
          a3_tag = assignment3.context_module_tags.new(context: @course, position: 2, tag_type: "context_module")
          a3_tag.context_module = first_context_module
          a3_tag.save!
        end

        context "sorting assignments only (no quizzes or discussions)" do
          it "sorts by module position, then context module tag position" do
            expected_id_order = [assignment3.id, assignment2.id, assignment1.id]
            expect(ordered_assignment_ids).to eq(expected_id_order)
          end

          it "sorts by module position, then context module tag position, " \
             "with those not belonging to a module sorted last" do
            assignment3.context_module_tags.first.destroy!
            expected_id_order = [assignment2.id, assignment1.id, assignment3.id]
            expect(ordered_assignment_ids).to eq(expected_id_order)
          end
        end

        context "sorting quizzes and discussions" do
          let(:assignment_owning_quiz) do
            assignment = @course.assignments.create!
            quiz = quiz_model(course: @course, assignment_id: assignment.id)
            quiz_context_module_tag =
              quiz.context_module_tags.build(context: @course, position: 4, tag_type: "context_module")
            quiz_context_module_tag.context_module = first_context_module
            quiz_context_module_tag.save!
            assignment
          end

          let(:assignment_owning_discussion_topic) do
            assignment = @course.assignments.create!(submission_types: "discussion_topic")
            discussion = @course.discussion_topics.create!
            assignment.discussion_topic = discussion
            assignment.save!
            discussion_context_module_tag =
              discussion.context_module_tags.build(context: @course, position: 5, tag_type: "context_module")
            discussion_context_module_tag.context_module = first_context_module
            discussion_context_module_tag.save!
            assignment
          end

          it "handles comparing quizzes to assignments" do
            expected_id_order = [assignment3.id, assignment2.id, assignment_owning_quiz.id, assignment1.id]
            expect(ordered_assignment_ids).to eq(expected_id_order)
          end

          it "handles comparing discussions to assignments" do
            expected_id_order = [assignment3.id, assignment2.id, assignment_owning_discussion_topic.id, assignment1.id]
            expect(ordered_assignment_ids).to eq(expected_id_order)
          end

          it "handles comparing discussions, quizzes, and assignments to each other" do
            expected_id_order = [
              assignment3.id,
              assignment2.id,
              assignment_owning_quiz.id,
              assignment_owning_discussion_topic.id,
              assignment1.id
            ]
            expect(ordered_assignment_ids).to eq(expected_id_order)
          end
        end
      end
    end

    context "assignment order: assignment_group" do
      let(:presenter) do
        GradeSummaryPresenter.new(@course, @teacher, @student.id, assignment_order: :assignment_group)
      end

      it "sorts by assignment group position then assignment position" do
        new_assignment_group = @course.assignment_groups.create!(position: 2)
        assignment4 = @course.assignments.create!(
          assignment_group: new_assignment_group, title: "Dog", position: 1
        )
        expected_id_order = [assignment1.id, assignment2.id, assignment3.id, assignment4.id]
        expect(ordered_assignment_ids).to eq(expected_id_order)
      end
    end
  end

  describe "#student_enrollment_for" do
    let(:gspcourse) do
      course_factory
    end

    let(:teacher) do
      teacher_in_course({ course: gspcourse }).user
    end

    let(:inactive_student_enrollment) do
      enrollment = course_with_user("StudentEnrollment", { course: gspcourse })
      enrollment.workflow_state = "inactive"
      enrollment.save!
      enrollment
    end

    let(:inactive_student) do
      inactive_student_enrollment.user
    end

    let(:other_student_enrollment) do
      course_with_user("StudentEnrollment", { course: gspcourse })
    end

    let(:other_student) do
      other_student_enrollment.user
    end

    it "includes active enrollments" do
      gsp = GradeSummaryPresenter.new(gspcourse, other_student, nil)
      enrollment = gsp.student_enrollment_for(gspcourse, other_student.id)

      expect(enrollment).to eq(other_student_enrollment)
    end

    it "doesn't include inactive enrollments" do
      gsp = GradeSummaryPresenter.new(gspcourse, inactive_student, nil)
      enrollment = gsp.student_enrollment_for(gspcourse, inactive_student.id)

      expect(enrollment).to be_nil
    end

    it "includes inactive enrollments if you can read grades" do
      gsp = GradeSummaryPresenter.new(gspcourse, teacher, inactive_student.id.to_s)
      enrollment = gsp.student_enrollment_for(gspcourse, inactive_student.id)

      expect(enrollment).to eq(inactive_student_enrollment)
    end
  end

  describe "#hidden_submissions_for_published_assignments?" do
    let_once(:course) { Course.create! }
    let_once(:student) { course.enroll_student(User.create!, enrollment_state: :active).user }
    let_once(:teacher) { course.enroll_teacher(User.create!, enrollment_state: :active).user }

    let_once(:assignment1) { course.assignments.create!(title: "a1", workflow_state: "published") }
    let_once(:assignment2) { course.assignments.create!(title: "a2", workflow_state: "published") }

    let_once(:presenter) { GradeSummaryPresenter.new(course, student, student.id) }

    before(:once) do
      assignment1.ensure_post_policy(post_manually: true)
      assignment2.ensure_post_policy(post_manually: false)
    end

    context "when the assignment posts manually" do
      it "returns true if any of the student's submissions are unposted and published assignment" do
        assignment1.grade_student(student, grader: teacher, score: 1)
        assignment1.hide_submissions

        expect(presenter).to be_hidden_submissions_for_published_assignments
      end

      it "returns false if any of the student's submissions are unposted and unpublished assignment" do
        assignment1.hide_submissions
        assignment1.unpublish

        expect(presenter).not_to be_hidden_submissions_for_published_assignments
      end

      it "returns false if any of the student's submissions are posted and published assignment" do
        assignment1.post_submissions
        assignment2.post_submissions

        expect(presenter).not_to be_hidden_submissions_for_published_assignments
      end
    end

    context "when the assignment posts automatically" do
      it "returns true if any of the student's submissions are graded, unposted and published assignment" do
        assignment1.ensure_post_policy(post_manually: false)
        assignment1.grade_student(student, grader: teacher, score: 1)
        assignment1.hide_submissions

        expect(presenter).to be_hidden_submissions_for_published_assignments
      end

      it "returns false if any of the student's submissions are ungraded, unposted and published assignment" do
        assignment1.ensure_post_policy(post_manually: false)
        assignment1.hide_submissions

        expect(presenter).not_to be_hidden_submissions_for_published_assignments
      end

      it "returns false if any of the student's submissions are ungraded, posted and published assignment" do
        assignment1.ensure_post_policy(post_manually: false)
        assignment1.grade_student(student, grader: teacher, score: 1)
        assignment1.post_submissions

        expect(presenter).not_to be_hidden_submissions_for_published_assignments
      end

      it "returns false if any of the student's submissions are graded, posted and unpublished assignment" do
        assignment1.ensure_post_policy(post_manually: false)
        assignment1.grade_student(student, grader: teacher, score: 1)
        assignment1.hide_submissions
        assignment1.unpublish

        expect(presenter).not_to be_hidden_submissions_for_published_assignments
      end

      it "returns false if any of the student's submissions are ungraded, posted and unpublished assignment" do
        assignment1.ensure_post_policy(post_manually: false)
        assignment1.post_submissions
        assignment1.unpublish

        expect(presenter).not_to be_hidden_submissions_for_published_assignments
      end
    end
  end

  describe "#show_updated_plagiarism_icons?" do
    let_once(:actual_plagiarism_data) do
      {
        provider: "turnitin",
        submission_0: { status: "pending" }
      }
    end
    let_once(:course) { Course.create! }
    let_once(:student) { course.enroll_student(User.create!, enrollment_state: :active).user }
    let_once(:presenter) { GradeSummaryPresenter.new(course, student, student.id) }

    it "returns false if no plagiarism data is supplied" do
      course.root_account.enable_feature!(:new_gradebook_plagiarism_indicator)
      expect(presenter).not_to be_show_updated_plagiarism_icons(nil)
    end

    it "returns false if vacuous plagiarism data is supplied" do
      course.root_account.enable_feature!(:new_gradebook_plagiarism_indicator)
      expect(presenter).not_to be_show_updated_plagiarism_icons({})
    end

    it "returns false if the new_gradebook_plagiarism_indicator flag is not enabled on the root account" do
      expect(presenter).not_to be_show_updated_plagiarism_icons(actual_plagiarism_data)
    end

    it "returns true if given plagiarism data and the new_gradebook_plagiarism_indicator flag is enabled" do
      course.root_account.enable_feature!(:new_gradebook_plagiarism_indicator)
      expect(presenter).to be_show_updated_plagiarism_icons(actual_plagiarism_data)
    end
  end
end
