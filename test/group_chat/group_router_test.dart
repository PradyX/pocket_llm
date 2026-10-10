import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';
import 'package:pocket_llm/features/group_chat/domain/group_router.dart';

void main() {
  Bot bot(String id, String name, {String soul = ''}) {
    return Bot.create(id: id, name: name, soul: soul);
  }

  final planner = bot('planner', 'Planner', soul: 'plans and tasks');
  final coder = bot('coder', 'Coder', soul: 'writes flutter code');
  final members = [planner, coder];

  GroupChat chat(SpeakerMode mode) {
    return GroupChat.create(
      workspaceId: 'ws',
      name: 'Room',
      memberBotIds: const ['planner', 'coder'],
    ).copyWith(mode: mode);
  }

  group('GroupRouter', () {
    test('mentions win in every mode', () {
      for (final mode in SpeakerMode.values) {
        expect(
          GroupRouter.nextSpeaker(
            chat: chat(mode),
            members: members,
            userText: '@coder fix this',
            workflowWaitingBotId: 'planner',
          ),
          'coder',
        );
      }
    });

    test('manual stays silent without a mention', () {
      expect(
        GroupRouter.nextSpeaker(
          chat: chat(SpeakerMode.manual),
          members: members,
          userText: 'hello everyone',
        ),
        isNull,
      );
    });

    test('workflow mode follows the waiting bot', () {
      expect(
        GroupRouter.nextSpeaker(
          chat: chat(SpeakerMode.workflow),
          members: members,
          userText: 'go',
          workflowWaitingBotId: 'planner',
        ),
        'planner',
      );
      // A bot that is not in the room never speaks.
      expect(
        GroupRouter.nextSpeaker(
          chat: chat(SpeakerMode.workflow),
          members: members,
          userText: 'go',
          workflowWaitingBotId: 'stranger',
        ),
        isNull,
      );
    });

    test('auto votes locally and stays silent on no overlap', () {
      expect(
        GroupRouter.nextSpeaker(
          chat: chat(SpeakerMode.auto),
          members: members,
          userText: 'who writes the flutter code?',
        ),
        'coder',
      );
      expect(
        GroupRouter.nextSpeaker(
          chat: chat(SpeakerMode.auto),
          members: members,
          userText: 'xqz jkl mno',
        ),
        isNull,
      );
    });

    test('follow-ups chain once and stop at the round cap', () {
      expect(
        GroupRouter.followUpSpeaker(
          members: members,
          botText: '@planner take a look',
          roundsUsed: 1,
          maxRounds: 10,
        ),
        'planner',
      );
      expect(
        GroupRouter.followUpSpeaker(
          members: members,
          botText: 'done, no mention here',
          roundsUsed: 1,
          maxRounds: 10,
        ),
        isNull,
      );
      expect(
        GroupRouter.followUpSpeaker(
          members: members,
          botText: '@planner again',
          roundsUsed: 10,
          maxRounds: 10,
        ),
        isNull,
      );
    });

    test('group chats persist round caps in range', () {
      final room = GroupChat.create(
        workspaceId: 'ws',
        name: 'R',
      ).copyWith(maxRounds: 500);
      expect(room.maxRounds, GroupChat.maxMaxRounds);
      expect(GroupMessage.user(chatId: 'c', text: 'hi').isUser, isTrue);
    });
  });
}
