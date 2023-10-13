/***************************************************************************************
* Copyright (c) 2014-2022 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <isa.h>
#include <memory/vaddr.h>

/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <regex.h>
#include <string.h>
#include <debug.h>

enum {
  TK_NOTYPE = 256, TK_EQ, TK_NEQ, TK_AND,
  TK_NUM, TK_REG, TK_DEREF,
};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {

  {"\\$[a-zA-Z0-9]+", TK_REG},     // regs name
  {"\\(", '('},
  {"\\)", ')'},
  {"\\*", '*'},         // mul  | op
  {"/", '/'},           // div  | op
  {" +", TK_NOTYPE},     // spaces
  {"\\+", '+'},         // plus | op
  {"-", '-'},           // sub  | op
  {"==", TK_EQ},        // equal
  {"!=", TK_NEQ},       // not equal
  {"&&", TK_AND},       // not equal
  {"((0x[0-9abcdef]+)|[0-9]+)[lL]?[lL]?[uU]?", TK_NUM},       // number
};

#define NR_REGEX ARRLEN(rules)

static regex_t re[NR_REGEX] = {};

/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
void init_regex() {
  int i;
  char error_msg[128];
  int ret;

  for (i = 0; i < NR_REGEX; i ++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[32];
} Token;

static Token tokens[128] __attribute__((used)) = {};
static int nr_token __attribute__((used))  = 0;

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;

  nr_token = 0;

  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        // Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s",
        //     i, rules[i].regex, position, substr_len, substr_len, substr_start);

        position += substr_len;

        tokens[nr_token].type = rules[i].token_type;

        switch (rules[i].token_type) {
          case TK_EQ:
          case TK_NEQ:
          case TK_AND:
            strncpy(tokens[nr_token].str, substr_start, substr_len);
            tokens[nr_token].str[substr_len] = '\0';
            nr_token++;
            break;
          case TK_NUM:
          case TK_REG:
            Assert(substr_len <= 32, "token str is longer than 32: %s", substr_start);
            strncpy(tokens[nr_token].str, substr_start, substr_len);
            tokens[nr_token].str[substr_len] = '\0';
            nr_token++;
            break;
          case TK_NOTYPE:
            break;
          default: 
            nr_token++;
            break;
        }

        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }

  return true;
}


int get_priority(Token *op){
  switch (op->type)
  {
  case '*':
  case '/':
    return -3;
  case '+':
  case '-':
    return -4;
  default: Assert(0, "Unexpected token: %d %c\n", op->type, op->type);
  }
}

bool check_parentheses(Token *p, Token *q) {
  if (p->type != '(' || q->type != ')') {
    return false;
  }
  p++; q--;
  for (int i = 0; p < q; )
  {
  if(p->type == '(') {
      i++;
    } 
    else if(p->type == ')') {
      i--;
    }
    if (i < 0) {
      return false;
    }
    p++;
  }
  return true;
}

bool is_op(Token *i){
  return (
    i->type == '*' || i->type == '/' || i->type == '+' || i->type == '-' ||
    i->type == TK_EQ || i->type == TK_NEQ || i->type == TK_AND || i->type == TK_DEREF
    );
}

word_t eval(Token *p, Token *q, bool *success) {
  if (p > q) {
    *success = false;
    return 0;
  }
  else if (p == q) {
    switch (p->type)
    {
    case TK_NUM: return strtoull(p->str, NULL, 0);
    case TK_REG: return isa_reg_str2val(p->str + 1, success);
    default: *success = 0; return 0;
    }
  }
  else if (check_parentheses(p, q) == true) {
    return eval(p + 1, q - 1, success);
  }
  else {
    Token *op = NULL;
    int b = 0;
    // backward to find op
    for (Token *it = p; it < q; it++)
    {
      if (it->type == '(') {
        b++;
      } 
      else if (it->type == ')') {
        b--;
      }
      if (b < 0){
        *success = false;
        return 0;
      }
      else if (
        (b == 0 && is_op(it)) &&
        (op == NULL || get_priority(op) >= get_priority(it))) {
        op = it;
      }
    }
    if (op == NULL) {
      *success = false;
      return 0;
    }
    // forward to find op
    int count = 0;
    while (op - (count + 1) >= p && is_op(op - (count + 1)))
    {
      count++;
    }
    op = op - count;
    // Log("%d %c %s", op->type, op->type, op->str);
    if (op > p) {
      // two variate operator
      word_t val1 = eval(p, op - 1, success);
      word_t val2 = eval(op + 1, q, success);
      // Log("%u %c %u", val1, op->type, val2);
      if (!success){
        return 0;
      }
      switch (op->type)
      {
      case '+': return (word_t)(val1 + val2);
      case '-': return (word_t)(val1 - val2);
      case '*': return (word_t)(val1 * val2);
      case '/': return (word_t)(val1 / val2);
      case TK_EQ: return val1 == val2;
      case TK_NEQ: return val1 != val2;
      case TK_AND: return val1 && val2;
      default: *success = 0; return 0;
      }
    }
    else {
      // one variate operator. a.k.a Unary.
      switch (op->type)
      {
      case '-': return -eval(op + 1, q, success);
      case TK_DEREF: return vaddr_read(eval(op+1, q, success), sizeof(word_t));
      default: *success = 0; return 0;
      }
    }
    return 0;
   
  }
}

word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }

  for (size_t i = 0; i < nr_token; i ++) {
    if (tokens[i].type == '*' && (i == 0 || is_op(&tokens[i - 1])) ) {
      tokens[i].type = TK_DEREF;
    }
  }

  word_t v = eval(&tokens[0], &tokens[nr_token - 1], success);
  return v;
}
